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

    /// Where the readings come from. Kept apart rather than mixed, because
    /// the two use different CAN headers and switching costs two adapter
    /// turnarounds - as much as a small page.
    enum Mode: Equatable {
        /// The proprietary V46.21 pages: everything the ECU knows, but a page
        /// answers with 40-70 bytes and BLE needs a notification per 20.
        case proprietary
        /// Standard mode-01 PIDs, up to six per request. Far fewer bytes, so
        /// this is the fast one - at the price of only the standard readings.
        case obd
    }

    // MARK: - what the screen watches

    @Published private(set) var state: State = .disconnected
    @Published private(set) var status = "Отключено"
    @Published private(set) var values: [String: Sample] = [:]
    /// Requests of pages the ECU did not answer when probed.
    @Published private(set) var deadPages: Set<String> = []

    /// Codes of standard PIDs this ECU does not publish. Measured on the car:
    /// seven of the twenty-one answer nothing, and each of those costs a full
    /// adapter timeout - 169 ms against 78 for one that answers, which was
    /// 1183 ms of a 2353 ms cycle spent waiting for nothing.
    @Published private(set) var deadPids: Set<String> = []

    // MARK: -

    private let profile: Profile
    private let obd: ObdSet?
    private let makeTransport: (TransportConfig) -> any ElmTransport

    private(set) var mode: Mode = .proprietary

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

    /// Whether the ECU honours several PIDs in one request. Assumed until an
    /// answer cannot be walked, then dropped for the rest of the session.
    private(set) var multiPid = true

    /// One adapter, several callers: the poll loop and any on-demand read.
    private let io = AsyncLock()
    private var adapter: Adapter?
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
         obd: ObdSet? = nil,
         makeTransport: @escaping (TransportConfig) -> any ElmTransport) {
        self.profile = profile
        self.obd = obd
        self.makeTransport = makeTransport
        self.selected = Self.defaultSelection(profile)
        if let obd {
            // The standard set starts fully on: it is cheap, and trimming it
            // is what the selection screen is for.
            self.selected.formUnion(obd.params.map(\.key))
        }
    }

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

    func rawReply(_ request: String) -> String? { lastReply[request] }

    func lastPageMs(_ request: String) -> Int? { lastMs[request] }

    func history(of key: String) -> [Point] { history[key] ?? [] }

    // MARK: - session

    func connect(_ config: TransportConfig, mode: Mode = .proprietary) {
        guard !isBusy else { return }
        self.mode = mode
        multiPid = true
        history = [:]
        lastReply = [:]
        lastMs = [:]
        skip = []
        cycle = 0
        values = [:]
        deadPages = []
        state = .connecting
        status = "Подключение…"

        let adapter = Adapter(transport: makeTransport(config))
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
    }

    private func run(_ adapter: Adapter) async {
        do {
            try await adapter.open()
            status = "Адаптер открыт, инициализация ЭБУ…"
            if techToFile { try? tech.start() }
            switch mode {
            case .proprietary: try await runProprietary(adapter)
            case .obd: try await runObd(adapter)
            }
        } catch {
            if !Task.isCancelled {
                status = "Ошибка: \(error.localizedDescription)"
                state = .failed
            }
        }
        stopLogging()
        adapter.close()
        loop = nil
    }

    private func runProprietary(_ adapter: Adapter) async throws {
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
        status = "Подключено" + (dead.isEmpty ? "" : " · без ответа: \(dead.count)")

        await pollLoop(adapter)
    }

    private func initEcu(_ adapter: Adapter) async -> Bool {
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
    private func probePages(_ adapter: Adapter) async -> Set<String> {
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
    private func tryPage(_ page: Profile.Page, _ adapter: Adapter) async -> Bool {
        let reply = await at(adapter, page.request, 1.5)
        lastReply[page.request] = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if Frames.isError(reply) { return false }
        let clean = Frames.clean(reply)
        guard let last = page.params.max(by: { $0.offset + $0.length < $1.offset + $1.length }) else {
            return clean.contains(page.marker)
        }
        return last.read(clean, marker: page.marker) != nil
    }

    private func pollLoop(_ adapter: Adapter) async {
        var live: [String: Sample] = [:]
        while !Task.isCancelled {
            cycle += 1
            let started = Date()

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
                if Frames.isError(reply) { continue }
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
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            status = "Подключено · цикл \(elapsed) мс"
            await keepAliveIfIdle(adapter)
        }
    }

    private func keepAliveIfIdle(_ adapter: Adapter) async {
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
    private func at(_ adapter: Adapter, _ command: String,
                    _ timeout: TimeInterval, note: String = "") async -> String {
        let reply = await adapter.send(command, timeout)
        guard tech.isRunning else { return reply }
        tech.log(TechLog.Exchange(
            at: Date(),
            mode: mode == .obd ? "obd" : "v4621",
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

    // MARK: - the standard OBD-II set

    private func runObd(_ adapter: Adapter) async throws {
        guard let obd else {
            status = "Стандартный набор недоступен: нет obd2.json"
            state = .failed
            return
        }
        let alive = try await io.locked { await self.initObd(adapter, obd) }
        guard alive else {
            status = "ЭБУ не отвечает на стандартный OBD (зажигание?)"
            state = .failed
            return
        }
        state = .connected
        startLogging(keys: obd.params.map(\.key).filter(selected.contains))
        status = "Проверка PID…"
        deadPids = try await io.locked { await self.probePids(adapter, obd) }
        status = "Подключено · стандартный OBD"
            + (deadPids.isEmpty ? "" : " · без ответа: \(deadPids.count)")
        await pollObd(adapter, obd)
    }

    /// Same adapter setup as the proprietary session, but addressed to the
    /// engine ECU's standard identifiers instead of the PSA ones, and the
    /// header is set once here rather than per page.
    private func initObd(_ adapter: Adapter, _ obd: ObdSet) async -> Bool {
        await at(adapter, "ATZ", 2.5)
        for command in ["ATD", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL"] {
            await at(adapter, command, 0.8)
        }
        await at(adapter, "ATAT2", 0.8)
        await at(adapter, "ATST" + Self.pollST, 0.8)
        await at(adapter, "ATSP6", 0.8)
        await adapter.applyHeader(obd.header.req, receive: obd.header.res)
        await at(adapter, "ATFCSH" + obd.header.req, 0.8)
        await at(adapter, "ATFCSD300000", 0.8)
        await at(adapter, "ATFCSM1", 0.8)
        // `0100` answers with the supported-PID bitmask; all that matters here
        // is that mode 01 is answered at all. No `81` - that is KWP, and the
        // standard set does not need a session opened.
        let reply = await at(adapter, "0100", 2.5)
        return !Frames.isError(reply) && Frames.clean(reply).hasPrefix("4100")
    }

    /// Ask each wanted PID once and remember the ones the ECU does not
    /// publish, the same way pages are probed. Without this the cycle pays an
    /// adapter timeout per unsupported PID, every pass, for nothing.
    private func probePids(_ adapter: Adapter, _ obd: ObdSet) async -> Set<String> {
        var dead: Set<String> = []
        for param in obd.params where selected.contains(param.key) {
            if Task.isCancelled { break }
            let reply = await at(adapter, param.pid, 1.5, note: "probe")
            if Frames.isError(reply)
                || ObdReply.walk(Frames.clean(reply), expecting: [param]) == nil {
                dead.insert(param.code)
            }
        }
        return dead
    }

    private func pollObd(_ adapter: Adapter, _ obd: ObdSet) async {
        var live: [String: Sample] = [:]
        while !Task.isCancelled {
            cycle += 1
            let started = Date()
            // A written-off PID is retried now and then in case the silence
            // was transient, like a dead page.
            let retry = cycle % 20 == 0
            let wanted = obd.params.filter {
                selected.contains($0.key) && (retry || !deadPids.contains($0.code))
            }

            for group in ObdReply.group(wanted, perRequest: multiPid ? 6 : 1) {
                if Task.isCancelled { break }
                let request = ObdReply.request(for: group)
                let sent = Date()
                let reply: String
                do {
                    reply = try await io.locked {
                        // Re-applied every group, and cheap when unchanged:
                        // reading fault codes switches the adapter to the PSA
                        // header, and without this the loop would carry on
                        // asking mode-01 PIDs on 6A8 and get nothing back for
                        // the rest of the session.
                        await adapter.applyHeader(obd.header.req, receive: obd.header.res)
                        return await at(adapter, request, 1.2)
                    }
                } catch {
                    break
                }
                let now = Date()
                lastMs[request] = Int(now.timeIntervalSince(sent) * 1000)
                lastReply[request] = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if Frames.isError(reply) { continue }

                guard let raws = ObdReply.walk(Frames.clean(reply), expecting: group) else {
                    // Either the ECU ignored the extra PIDs, or one answered
                    // with a different length than the table expects - and then
                    // every value after it would be read from the wrong place.
                    if group.count > 1 {
                        multiPid = false
                        status = "ЭБУ не принял мульти-PID, читаю по одному"
                        tech.log(TechLog.Exchange(
                            at: now, mode: "obd", command: request,
                            replyChars: reply.count, stats: LinkStats(), ms: 0,
                            ok: false, note: "multipid-refused",
                            reply: Frames.clean(reply)))
                    }
                    continue
                }
                for param in group {
                    guard let raw = raws[param.code] else { continue }
                    deadPids.remove(param.code)
                    let sample = Sample(value: param.value(raw), raw: raw,
                                        at: now, valid: true)
                    live[param.key] = sample
                    append(Point(at: now, value: sample.value), to: param.key)
                }
            }

            values = live
            record(live)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let per = multiPid ? "по 6" : "по одному"
            status = "Стандартный OBD · цикл \(elapsed) мс · \(per)"
        }
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

/// The adapter side of a session: one command at a time, plus the CAN header
/// the adapter is currently set to.
///
/// An actor is right here - each method is a single exchange and does not need
/// to stay indivisible across several of them; that is what `AsyncLock` is for.
actor Adapter {
    private let transport: any ElmTransport
    private var header: String?
    private var lastCommand = Date.distantPast

    /// What the last exchange cost, for the technical log.
    private(set) var lastStats = LinkStats()
    private(set) var lastMs = 0

    init(transport: any ElmTransport) {
        self.transport = transport
    }

    func open() async throws {
        try await transport.open()
    }

    nonisolated func close() {
        transport.close()
    }

    func idleFor() -> TimeInterval {
        Date().timeIntervalSince(lastCommand)
    }

    func applyHeader(_ header: String, receive: String) async {
        guard self.header != header else { return }
        await send("ATSH" + header, 0.6)
        await send("ATCRA" + receive, 0.6)
        self.header = header
    }

    /// Sends one ELM command (adds CR) and reads until the `>` prompt or the
    /// timeout.
    ///
    /// The drain first is not optional. Anything still buffered belongs to an
    /// earlier exchange - a reply that arrived after its timeout, or trailing
    /// bytes after the prompt. Left in place it is read as the answer to the
    /// next command, and from then on every read returns the previous page's
    /// data: the marker no longer matches, so page after page looks dead.
    @discardableResult
    func send(_ command: String, _ timeout: TimeInterval) async -> String {
        transport.drain()
        do {
            try await transport.write(command + "\r")
        } catch {
            return ""
        }
        lastCommand = Date()
        let started = Date()
        let reply = await transport.read(until: ">", timeout: timeout)
        lastMs = Int(Date().timeIntervalSince(started) * 1000)
        lastStats = transport.stats
        return reply
    }
}
