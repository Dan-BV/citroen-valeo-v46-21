import Foundation

/// Talks to the Valeo V46.21 engine ECU over CAN.
///
/// Port of android/app/src/main/java/com/fap/modern/core/ElmSession.kt. KWP2000
/// on ISO 15765-2, request id 6A8, response id 688, taken from the Diagbox
/// databases and confirmed on the car. `81` opens the session and is mandatory:
/// the proprietary `21xx` pages answer nothing without it.
///
/// K-line is not implemented, as on Android - and on iOS could not be: the
/// adapter has to be BLE here.
@MainActor
final class ElmSession: ObservableObject {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    // MARK: - what the screen watches

    @Published private(set) var state: State = .disconnected
    @Published private(set) var status = "Отключено"
    /// Wall time of the last completed poll cycle. Kept apart from `status`
    /// so the screen can set it large: it is the one number watched while
    /// driving.
    @Published private(set) var lastCycleMs: Int?
    /// What `status` says while the cycle runs; the loop restores it after a
    /// transient message such as a session reopen.
    private var liveStatus = "Подключено"
    @Published private(set) var values: [String: Sample] = [:]
    /// Requests of pages the ECU did not answer when probed.
    @Published private(set) var deadPages: Set<String> = []

    // MARK: -

    private let profile: Profile
    /// Which adapter to build for a chosen config.
    ///
    /// A factory rather than a transport, because there are two kinds of
    /// adapter now and only the caller knows which a config means. Everything
    /// below this line talks to `any Adapter` and cannot tell them apart.
    private let makeAdapter: (TransportConfig) -> any Adapter

    private let logger = CsvLogger()
    private let tech = TechLog()

    /// Whether every exchange is measured into a second file. On for now: the
    /// open questions about where the cycle time goes are all answered by that
    /// file and by nothing else.
    @Published var techToFile = true

    var techURL: URL? { tech.url }
    @Published private(set) var techRows = 0

    /// Whether a connect starts a recording. On by default: a drive that was
    /// not logged cannot be analysed afterwards, and the file is deleted again
    /// if no row was written.
    @Published var logToFile = true

    /// Rows written so far, for the recording indicator.
    @Published private(set) var loggedRows = 0

    var logURL: URL? { logger.url }

    /// One adapter, several callers: the poll loop and any on-demand read.
    private let io = AsyncLock()
    private var adapter: (any Adapter)?
    private var loop: Task<Void, Never>?

    private var history: [String: [Point]] = [:]
    private let historyCap = 6000

    /// Last raw reply per page, for the on-screen page diagnostic.
    private var lastReply: [String: String] = [:]

    /// Wall time of the last read of each page. A cycle is the sum of these and
    /// nothing else, so this is where to look before trimming anything: a page
    /// costs one adapter turnaround, the parameters inside it cost nothing.
    private var lastMs: [String: Int] = [:]

    /// Which parameters the user wants. A page with nothing selected is not
    /// asked for at all - that, not any adapter trick, is what shortens the
    /// cycle. Published, because the switches on screen read it back.
    @Published private(set) var selected: Set<String>

    private var skip: Set<String> = []
    private var cycle: Int64 = 0

    /// When the ECU last gave a reading that parsed. A stalled session hangs
    /// off this: whether to remind the user, and whether a lit screen is still
    /// worth the battery.
    private var lastValidAt = Date()
    private var wasStalled = false
    private var screenHeld = false

    /// Quiet for this long and the car has stopped answering rather than
    /// hesitating. Ordinary gaps of 7-11 s appear in the 2026-09-10 logs, so
    /// the threshold sits well past them.
    private let stallAfter: TimeInterval = 60

    /// Consecutive poll cycles in which every page asked came back an error.
    private var mutePasses = 0
    /// Re-opening is cheap but not free, and a silent ECU stays silent.
    private var lastReopen = Date.distantPast

    /// Adapter reply timeout, in ELM units of 4 ms: 0x19 = 100 ms. The default
    /// is 0x32 (200 ms) and the ceiling 0xFF (1020 ms); with adaptive timing on
    /// this is the cap, not the usual wait.
    private static let pollST = "19"

    /// How often each page is read and what each one costs, remembered between
    /// sessions so the effect of a change can be shown before setting off.
    let plan = PagePlan()

    /// Pages nothing is selected from by default, so they are never asked for.
    /// $B0 is the immobilizer and $CF the ZAPV service record; both hold still
    /// while driving. This is where cycle time actually goes: a page costs one
    /// adapter turnaround and the parameters inside it cost nothing, so the
    /// Android base set buys its speed by leaving these two out entirely
    /// rather than by dropping parameters.
    static let staticPages: Set<String> = ["B0", "CF"]

    /// What is selected when nothing has been chosen yet: everything except
    /// the two static pages.
    static func defaultSelection(_ profile: Profile) -> Set<String> {
        Set(profile.pages
            .filter { !staticPages.contains($0.id ?? "") }
            .flatMap { $0.params.map(\.key) })
    }

    /// Every key the profile knows, for a screen that wants to offer them all.
    static func allKeys(_ profile: Profile) -> Set<String> {
        Set(profile.pages.flatMap { $0.params.map(\.key) })
    }

    /// Pages the cycle currently asks for, in profile order, with how often.
    var polledPages: [(page: Profile.Page, period: Int)] {
        profile.pages.filter(anyOn).map { ($0, periodOf($0)) }
    }

    var isConnected: Bool { state == .connected }
    var isBusy: Bool { loop != nil }

    init(profile: Profile,
         makeAdapter: @escaping (TransportConfig) -> any Adapter) {
        self.profile = profile
        self.makeAdapter = makeAdapter
        self.selected = Self.defaultSelection(profile)    }

    // MARK: - selection

    func setSelection(_ keys: Set<String>) { selected = keys }

    func isSelected(_ key: String) -> Bool { selected.contains(key) }

    /// Turning a whole page off is what makes the cycle shorter; turning a
    /// single parameter off only tidies the screen.
    func setPage(_ page: Profile.Page, on: Bool) {
        let keys = Set(page.params.map(\.key))
        selected = on ? selected.union(keys) : selected.subtracting(keys)
    }

    func toggle(_ key: String) {
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }

    func toggle(_ field: Profile.Field) { toggle(field.key) }

    private func isOn(_ field: Profile.Field) -> Bool { selected.contains(field.key) }

    private func anyOn(_ page: Profile.Page) -> Bool { page.params.contains(where: isOn) }

    /// Cycles between reads of a page: the reader's choice if there is one,
    /// otherwise the default the Android app arrived at.
    func periodOf(_ page: Profile.Page) -> Int {
        plan.period(of: page)
    }

    func setPeriod(_ period: Int, for page: Profile.Page) {
        plan.setPeriod(period, for: page)
        objectWillChange.send()
    }

    /// What a cycle will take at the current selection and periods, from the
    /// round trips this adapter actually showed. `nil` until something has been
    /// measured.
    var predictedCycleMs: Int? {
        plan.predictedCycleMs(profile.pages.filter(anyOn))
    }

    var cycleBreakdown: [(page: Profile.Page, share: Int)] {
        plan.breakdown(profile.pages.filter(anyOn))
    }

    /// How many of a page's parameters are wanted, out of how many it carries.
    ///
    /// This is the number the reader trades against: a page costs one adapter
    /// turnaround whether one parameter is taken from it or twenty-five, so a
    /// page carrying two wanted readings is expensive and one carrying twenty
    /// is nearly free. Measured on the car, a page runs 4.7 to 12.9 ms per
    /// parameter it delivers - which is why the fastest way to a small set is
    /// the one page that covers most of it, not more requests.
    func wantedOn(_ page: Profile.Page) -> (wanted: Int, total: Int) {
        // Not count(where:) - that is Swift 6, and this target builds as 5.
        let wanted = page.params.lazy.filter { self.selected.contains($0.key) }.count
        return (wanted, page.params.count)
    }

    func rawReply(_ request: String) -> String? { lastReply[request] }

    func lastPageMs(_ request: String) -> Int? { lastMs[request] }

    func history(of key: String) -> [Point] { history[key] ?? [] }

    // MARK: - session

    func connect(_ config: TransportConfig) {
        guard !isBusy else { return }
        history = [:]
        lastReply = [:]
        lastMs = [:]
        skip = []
        cycle = 0
        values = [:]
        deadPages = []
        lastValidAt = Date()
        wasStalled = false
        mutePasses = 0
        state = .connecting
        status = "Подключение…"
        lastCycleMs = nil

        // The screen must not sleep while a session runs: a suspended app
        // means a gap, and the ECU drops its session across a gap.
        setScreenHeld(true)
        StallReminder.shared.onStop = { [weak self] in self?.disconnect() }
        Task { await StallReminder.shared.prepare() }

        let adapter = makeAdapter(config)
        self.adapter = adapter
        loop = Task { await run(adapter) }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        adapter?.close()
        adapter = nil
        state = .disconnected
        status = "Отключено"
        lastCycleMs = nil
        setScreenHeld(false)
        StallReminder.shared.sessionEnded()
    }

    private func run(_ adapter: any Adapter) async {
        do {
            try await adapter.open()
            status = "Адаптер открыт, инициализация ЭБУ…"
            if techToFile { try? tech.start() }
            try await runProprietary(adapter)
        } catch {
            if !Task.isCancelled {
                status = "Ошибка: \(error.localizedDescription)"
                state = .failed
            }
        }
        stopLogging()
        adapter.close()
        loop = nil
        setScreenHeld(false)
        StallReminder.shared.sessionEnded()
    }

    /// Idempotent, so the two teardown paths cannot leave the hold stuck on.
    private func setScreenHeld(_ held: Bool) {
        guard held != screenHeld else { return }
        screenHeld = held
        held ? DeviceAwake.hold() : DeviceAwake.release()
    }

    private func runProprietary(_ adapter: any Adapter) async throws {
        let alive = try await io.locked { await self.initEcu(adapter) }
        guard alive else {
            status = "ЭБУ не отвечает (адаптер / зажигание)"
            state = .failed
            return
        }

        state = .connected
        startLogging(keys: profile.pages.flatMap { page in
            page.params.map(\.key).filter(selected.contains)
        })
        status = "Проверка доступных страниц…"
        let dead = try await io.locked { await self.probePages(adapter) }
        deadPages = dead
        liveStatus = "Подключено" + (dead.isEmpty ? "" : " · без ответа: \(dead.count)")
        status = liveStatus

        await pollLoop(adapter)
    }

    private func initEcu(_ adapter: any Adapter) async -> Bool {
        await at(adapter, "ATZ", 2.5)
        for command in ["ATD", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL"] {
            await at(adapter, command, 0.8)
        }
        // After a reply is assembled the adapter still sits waiting in case a
        // second module answers, and that wait - not the CAN traffic - is most
        // of a page's cost. Nothing else can answer here: ATCRA688 filters to
        // this ECU. AT2 lets the adapter shorten the wait to what the ECU
        // actually takes, ATST caps what it may wait when it guesses wrong.
        // If a page starts reading NO DATA, raise pollST before blaming it.
        await at(adapter, "ATAT2", 0.8)
        await at(adapter, "ATST" + Self.pollST, 0.8)
        await at(adapter, "ATSP6", 0.8)
        await adapter.applyHeader(profile.can.req, receive: profile.can.res)
        await at(adapter, "ATFCSH" + profile.can.req, 0.8)
        await at(adapter, "ATFCSD300000", 0.8)
        await at(adapter, "ATFCSM1", 0.8)
        await at(adapter, "81", 2.5)

        // Consider the ECU reachable if any of the first few pages answers - a
        // single page can be one this variant does not implement, and that is
        // not a reason to call the whole connection dead.
        for page in profile.pages.prefix(3) {
            let reply = await at(adapter, page.request, 2.5)
            if !Frames.isError(reply), Frames.clean(reply).contains(page.marker) {
                return true
            }
        }
        return false
    }

    /// Ask every page once and remember the ones this ECU does not answer, so
    /// the cycle stops paying an adapter timeout for them.
    private func probePages(_ adapter: any Adapter) async -> Set<String> {
        for page in profile.pages {
            await adapter.applyHeader(profile.can.req, receive: profile.can.res)
            if await tryPage(page, adapter) { continue }
            // One more try: the first failure can be the tail of an earlier
            // desync rather than a page this ECU lacks.
            if await tryPage(page, adapter) { continue }
            if await tryPage(page, adapter) { continue }
            skip.insert(page.request)
        }
        return skip
    }

    /// Validate against the field that ends last, not the first one. A reply
    /// cut short still carries the early fields, so checking the first field
    /// lets a truncated page pass as healthy - which is exactly how the whole
    /// of $C0, $C2, $CA and $CF went missing while looking connected.
    private func tryPage(_ page: Profile.Page, _ adapter: any Adapter) async -> Bool {
        let reply = await at(adapter, page.request, 1.5)
        lastReply[page.request] = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if Frames.isError(reply) { return false }
        let clean = Frames.clean(reply)
        guard let last = page.params.max(by: { $0.offset + $0.length < $1.offset + $1.length }) else {
            return clean.contains(page.marker)
        }
        return last.read(clean, marker: page.marker) != nil
    }

    private func pollLoop(_ adapter: any Adapter) async {
        var live: [String: Sample] = [:]
        while !Task.isCancelled {
            cycle += 1
            let started = Date()
            var asked = 0
            var answered = false

            for page in profile.pages {
                if Task.isCancelled { break }
                // A page that holds still is read now and then rather than
                // every pass; dead ones get an occasional retry in case the
                // failure was transient.
                let period = periodOf(page)
                if period > 1, cycle % Int64(period) != 1 { continue }
                if skip.contains(page.request), cycle % 20 != 0 { continue }
                if !anyOn(page) { continue }

                let sent = Date()
                let reply: String
                do {
                    reply = try await io.locked {
                        await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
                        return await at(adapter, page.request, 1.2)
                    }
                } catch {
                    break
                }
                let now = Date()
                let took = Int(now.timeIntervalSince(sent) * 1000)
                lastMs[page.request] = took
                lastReply[page.request] = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                asked += 1
                if Frames.isError(reply) { continue }
                answered = true
                lastValidAt = now
                skip.remove(page.request)
                plan.record(took, for: page)

                let clean = Frames.clean(reply)
                for field in page.params where isOn(field) {
                    guard let (raw, _) = field.read(clean, marker: page.marker) else {
                        live[field.key] = Sample(value: 0, raw: 0, at: now, valid: false)
                        continue
                    }
                    let sample = Sample(value: field.value(fromMasked: raw),
                                        raw: raw, at: now, valid: true)
                    live[field.key] = sample
                    // Only numbers have a curve worth keeping; a text state is
                    // not something to draw.
                    if field.kind == .numeric {
                        append(Point(at: now, value: sample.value), to: field.key)
                    }
                }
            }

            values = live
            record(live)
            lastCycleMs = Int(Date().timeIntervalSince(started) * 1000)
            if status != liveStatus { status = liveStatus }

            // The adapter being gone is not a page that failed to answer,
            // and telling them apart is the difference between ending the
            // session and polling a pipe that cannot reply.
            if await adapter.linkFailure != nil {
                linkLost()
                return
            }

            // Belt and braces for any other way of failing instantly: a cycle
            // that asked and heard nothing waits before the next one. Without
            // it a link that fails without blocking spins at two thousand
            // exchanges a second, which is how 2026-09-10 filled a 4.7 MB log
            // with nothing.
            if asked > 0, !answered {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // A cycle where every page asked came back an error is the ECU
            // having dropped its diagnostic session, not a bad reply. Two in a
            // row rules out a single glitch.
            if asked > 0 {
                mutePasses = answered ? 0 : mutePasses + 1
            }
            if mutePasses >= 2, Date().timeIntervalSince(lastReopen) > 5 {
                await reopen(adapter)
            }

            let quiet = Date().timeIntervalSince(lastValidAt)
            let stalled = quiet >= stallAfter
            if stalled != wasStalled {
                // Nothing to read means nothing to look at, so stop paying for
                // a lit screen until the car answers again.
                setScreenHeld(!stalled)
                if !stalled { StallReminder.shared.reset() }
                wasStalled = stalled
            }
            if stalled { StallReminder.shared.stalled(for: quiet) }

            await keepAliveIfIdle(adapter)
        }
    }

    /// The adapter itself is gone - ignition off and the port unpowered, out
    /// of range, a flat adapter battery. End the session rather than poll
    /// something that cannot answer, and say so on screen instead of leaving
    /// "Подключено" up.
    ///
    /// Teardown is left to `run`, which stops the log, closes the adapter and
    /// releases the screen as soon as this returns.
    private func linkLost() {
        status = "Связь с адаптером потеряна · запись остановлена"
        // Or the strip would keep showing the cycle time of a session that is
        // no longer running - which is exactly how this looked from the car:
        // "Подключено · 0 мс" with nothing behind it.
        lastCycleMs = nil
        state = .failed
        StallReminder.shared.linkLost()
    }

    /// Re-open a diagnostic session the ECU has dropped.
    ///
    /// `81` is what opens it, and until now that ran only at connect - so once
    /// the car went quiet every page answered `NO DATA` for ever and the only
    /// way out was a human reconnecting. Measured on 2026-09-10:
    /// `out/drives/2026-09-10_ios_baseline.md`.
    private func reopen(_ adapter: any Adapter) async {
        mutePasses = 0
        lastReopen = Date()
        status = "Сессия ЭБУ потеряна, переоткрываю…"
        let opened = (try? await io.locked {
            await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
            return !Frames.isError(await self.at(adapter, "81", 2.5, note: "reopen"))
        }) ?? false
        if opened {
            status = liveStatus
            return
        }
        // The adapter itself may have lost the thread - a power blip on the
        // OBD port does that - so redo the handshake before giving up on the
        // cycle.
        _ = try? await io.locked { await self.initEcu(adapter) }
    }

    private func keepAliveIfIdle(_ adapter: any Adapter) async {
        guard await adapter.idleFor() > 2.5 else { return }
        _ = try? await io.locked { await at(adapter, "3E", 0.8) }
    }

    // MARK: - recording

    /// Send one command and note what it cost.
    ///
    /// Everything the session asks for goes through here, so the technical log
    /// covers short AT commands as well as page reads - the short ones are what
    /// gives the fixed cost per exchange, and the difference is what gives the
    /// cost per byte. The two `ATSH`/`ATCRA` writes inside `Adapter.applyHeader`
    /// are the exception; they are the same shape as the other AT commands, so
    /// their cost reads off those.
    @discardableResult
    private func at(_ adapter: any Adapter, _ command: String,
                    _ timeout: TimeInterval, note: String = "") async -> String {
        let reply = await adapter.send(command, timeout)
        guard tech.isRunning else { return reply }
        tech.log(TechLog.Exchange(
            at: Date(),
            // One mode now; the column stays because the analyser reads it.
            mode: "v4621",
            command: command,
            replyChars: reply.count,
            stats: await adapter.lastStats,
            ms: await adapter.lastMs,
            ok: !reply.isEmpty && !Frames.isError(reply),
            note: note,
            reply: Frames.clean(reply)))
        return reply
    }


    private func startLogging(keys: [String]) {
        guard logToFile, !keys.isEmpty else { return }
        do {
            try logger.start(keys: keys)
            loggedRows = 0
        } catch {
            status = "Запись не открылась: \(error.localizedDescription)"
        }
    }

    private func record(_ values: [String: Sample]) {
        techRows = tech.rows
        guard logger.isRunning else { return }
        logger.log(Date(), values)
        loggedRows = logger.rows
    }

    private func stopLogging() {
        logger.stop()
        tech.stop()
    }

    /// Push what is buffered, so a file can be shared without stopping.
    func flushLog() {
        logger.flush()
        tech.flush()
    }

    // MARK: - on demand

    /// `17 FF 00` -> `57 <count> [ code(2) status(1) ] x count`.
    func readDtc() async throws -> [Dtc] {
        guard let adapter else { throw TransportError.notOpen }
        return try await io.locked {
            await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
            let reply = await at(adapter, "17FF00", 3.0)
            return try Self.parseDtc(reply, dictionary: self.profile.dtc)
        }
    }

    /// Split out of `readDtc` so the parsing can be tested without an adapter.
    static func parseDtc(_ reply: String, dictionary: [String: String]) throws -> [Dtc] {
        if Frames.isError(reply) {
            throw SessionError.noAnswer("17FF00")
        }
        let clean = Frames.clean(reply)
        guard clean.hasPrefix("57") else {
            throw SessionError.unexpected(String(clean.prefix(24)))
        }
        let digits = Array(clean)
        guard digits.count >= 4, let count = Int(String(digits[2..<4]), radix: 16) else {
            return []
        }
        var out: [Dtc] = []
        for i in 0..<count {
            let at = 4 + i * 6
            guard at + 6 <= digits.count else { break }
            let code = String(digits[at..<(at + 4)])
            let status = String(digits[(at + 4)..<(at + 6)])
            out.append(Dtc(code: code, status: status, label: dictionary[code]))
        }
        return out
    }

    func clearDtc() async throws {
        guard let adapter else { throw TransportError.notOpen }
        try await io.locked {
            await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
            let clean = Frames.clean(await at(adapter, "14FF00", 3.0))
            guard clean.hasPrefix("54") else {
                throw SessionError.notCleared(clean.isEmpty ? "нет ответа" : String(clean.prefix(24)))
            }
        }
    }

    func readIdent() async throws -> [IdentBlock] {
        guard let adapter else { throw TransportError.notOpen }
        return try await io.locked {
            await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
            var out: [IdentBlock] = []
            for block in self.profile.ident {
                let reply = await at(adapter, block.request, 2.5)
                if Frames.isError(reply) { continue }
                let clean = Frames.clean(reply)
                guard clean.contains(block.marker) else { continue }
                let rows = Self.identRows(of: block, in: clean)
                if !rows.isEmpty { out.append(IdentBlock(title: block.title, rows: rows)) }
            }
            return out
        }
    }

    static func identRows(of block: Profile.Page, in clean: String) -> [(String, String)] {
        block.params.compactMap { field in
            guard let (raw, reading) = field.read(clean, marker: block.marker) else { return nil }
            let shown: String
            switch reading {
            case let .state(_, label):
                shown = label ?? "?\(raw)"
            case let .hex(digits):
                shown = digits
            case .number:
                shown = "\(raw)"
            }
            return (field.label, shown)
        }
    }

    // MARK: -

    private func append(_ point: Point, to key: String) {
        var points = history[key] ?? []
        points.append(point)
        if points.count > historyCap { points.removeFirst(points.count - historyCap) }
        history[key] = points
    }
}

enum SessionError: LocalizedError, Equatable {
    case noAnswer(String)
    case unexpected(String)
    case notCleared(String)

    var errorDescription: String? {
        switch self {
        case let .noAnswer(what):
            return "Нет ответа на \(what)"
        case let .unexpected(what):
            return "Неожиданный ответ: \(what)"
        case let .notCleared(what):
            return "ЭБУ не подтвердил стирание: \(what)"
        }
    }
}
