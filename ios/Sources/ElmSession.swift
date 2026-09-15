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

    /// How the last attempt to bring the link up went, step by step.
    ///
    /// Empty for an ELM327 clone, which has nothing to say. A ThinkDiag's
    /// opening is eight exchanges of a reverse-engineered protocol, and when
    /// it fails the whole diagnosis is which step stopped answering - so it
    /// has to reach the screen, not only the actor that recorded it.
    @Published private(set) var openingReport: [String] = []

    /// The module handles the open adapter addresses modules by, empty for an
    /// ELM327. A screen offers the handle sweep only when there is one to
    /// offer, and only the open adapter knows.
    @Published private(set) var adapterLinks: [UInt16] = []

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

    /// The columns the open recording has. Frozen when the file is opened - a
    /// CSV cannot grow a column halfway down - so a parameter added to a
    /// dashboard mid-drive is shown but not written, and the tile says so
    /// rather than leaving it to be discovered in the file afterwards.
    @Published private(set) var recordedKeys: Set<String> = []

    var logURL: URL? { logger.url }

    /// One adapter, several callers: the poll loop and any on-demand read.
    private let io = AsyncLock()
    private var adapter: (any Adapter)?
    private var loop: Task<Void, Never>?

    /// Bumped by every `connect` and `disconnect`. A `run` task tears down
    /// shared session state only while its own generation is still current, so
    /// a cancelled session unwinding late cannot stop the logging - or nil the
    /// loop handle - of the session that replaced it. Without this, a reconnect
    /// right after a disconnect was clobbered by the old task's teardown, and
    /// the only way back was to kill the app.
    private var runGeneration = 0

    private var history: [String: [Point]] = [:]
    private let historyCap = 6000

    /// Last raw reply per page, for the on-screen page diagnostic.
    private var lastReply: [String: String] = [:]

    /// Wall time of the last read of each page. A cycle is the sum of these and
    /// nothing else, so this is where to look before trimming anything: a page
    /// costs one adapter turnaround, the parameters inside it cost nothing.
    private var lastMs: [String: Int] = [:]

    /// Which parameters the reader ticked in the list. A page with nothing on
    /// it is not asked for at all - that, not any adapter trick, is what
    /// shortens the cycle. Published, because the switches on screen read it
    /// back.
    ///
    /// This is the list's half of the answer only; what the cycle goes by is
    /// `polled`.
    @Published private(set) var selected: Set<String> {
        didSet {
            selection.save(selected)
            polled = selected.union(dashboardKeys)
        }
    }

    /// What the dashboards need read, handed over by the screen that owns them.
    ///
    /// The session deliberately does not know what a dashboard is: it is given
    /// a set of keys and merges it with the list's. That is the whole of the
    /// duplication question - two screens wanting the same parameter are two
    /// members of one set, so it is read once, kept once and logged once.
    @Published private(set) var dashboardKeys: Set<String> = [] {
        didSet { polled = selected.union(dashboardKeys) }
    }

    /// The union: the one set the poll loop and the recording go by.
    ///
    /// Stored rather than computed because the loop asks it once per parameter
    /// per cycle, and a set union per question is a cost with nothing to show
    /// for it.
    @Published private(set) var polled: Set<String>

    private let selection: SelectionStore

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

    /// How often the log buffers are written out to disk while a session runs.
    /// Appends only buffer in memory; without this the whole drive sat unwritten
    /// until the logs screen was opened or the session ended, so a crash or an
    /// app kill lost it. Five seconds bounds both the loss and the buffer, and
    /// the write is a few kilobytes off the poll's critical path.
    private static let flushInterval: TimeInterval = 5
    private var lastFlush = Date()

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
         makeAdapter: @escaping (TransportConfig) -> any Adapter,
         selection: SelectionStore = SelectionStore()) {
        self.profile = profile
        self.makeAdapter = makeAdapter
        self.selection = selection
        let chosen = selection.load(valid: Self.allKeys(profile))
            ?? Self.defaultSelection(profile)
        self.selected = chosen
        // `didSet` does not run for an assignment inside `init`, so the union
        // is seeded here; the dashboards' half arrives from the screen.
        self.polled = chosen
    }

    // MARK: - selection

    func setSelection(_ keys: Set<String>) { selected = keys }

    /// Told by the screen that owns the dashboards, whenever they change.
    func setDashboardKeys(_ keys: Set<String>) {
        guard keys != dashboardKeys else { return }
        dashboardKeys = keys
    }

    /// Read only what the dashboards show. The one lever that actually shortens
    /// a cycle is asking for fewer pages, and this is it in a single tap.
    func readOnlyDashboards() {
        guard !dashboardKeys.isEmpty else { return }
        selected = dashboardKeys
    }

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

    /// Whether anything wants this parameter - the list, a dashboard, or both.
    private func isOn(_ field: Profile.Field) -> Bool { polled.contains(field.key) }

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

    /// How many of a page's parameters a dashboard holds. A page the list has
    /// switched off but a tile still shows stays in the cycle, and the switch
    /// alone cannot explain why - so the header says so.
    func dashboardHolds(_ page: Profile.Page) -> Int {
        page.params.lazy.filter { self.dashboardKeys.contains($0.key) }.count
    }

    /// Pages in the cycle only because a dashboard asks for them: what the
    /// dashboards cost, in the only unit that matters.
    var dashboardOnlyPages: [Profile.Page] {
        profile.pages.filter { page in
            page.params.contains(where: { self.dashboardKeys.contains($0.key) })
                && !page.params.contains(where: { self.selected.contains($0.key) })
        }
    }

    /// The recording's columns: every polled parameter, in profile order.
    ///
    /// Built by walking the profile rather than the selection, which is what
    /// makes a duplicate column impossible: the profile names each key exactly
    /// once and `polled` is a set, so a parameter shown in the list and on
    /// three tiles is one column here.
    var logKeys: [String] {
        profile.pages.flatMap { $0.params.map(\.key).filter(polled.contains) }
    }

    func rawReply(_ request: String) -> String? { lastReply[request] }

    func lastPageMs(_ request: String) -> Int? { lastMs[request] }

    func history(of key: String) -> [Point] { history[key] ?? [] }

    /// The tail of a curve, for a tile that draws the last minute of it.
    ///
    /// A slice rather than the whole series: up to six thousand points are kept
    /// per parameter and a dashboard redraws every tile every cycle, so handing
    /// each of them the lot is the one way a dashboard could cost real time.
    /// The points are appended in order, so the start of the window is a binary
    /// search.
    func history(of key: String, seconds: TimeInterval) -> [Point] {
        guard let points = history[key], let last = points.last else { return [] }
        let from = last.at.addingTimeInterval(-seconds)
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].at < from { low = middle + 1 } else { high = middle }
        }
        return Array(points[low...])
    }

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

        // A stale log from a session that has not finished tearing down must
        // not be written into, nor left showing as "recording"; start clean.
        stopLogging()

        runGeneration += 1
        let generation = runGeneration
        let adapter = makeAdapter(config)
        self.adapter = adapter
        loop = Task { await run(adapter, generation: generation) }
    }

    func disconnect() {
        // Invalidate the running task's teardown before it runs: it may be
        // parked in a read and unwind only seconds later, and by then this
        // session is over. Everything it would do is done here, now, so the
        // state is correct the instant the button is tapped.
        runGeneration += 1
        loop?.cancel()
        loop = nil
        adapter?.close()
        adapter = nil
        // Deterministically, not via the cancelled task's late teardown - which
        // is why a stopped session used to still show a log as "recording".
        stopLogging()
        state = .disconnected
        status = "Отключено"
        lastCycleMs = nil
        setScreenHeld(false)
        StallReminder.shared.sessionEnded()
    }

    private func run(_ adapter: any Adapter, generation: Int) async {
        openingReport = []
        do {
            try await adapter.open()
            openingReport = await adapter.openingReport
            adapterLinks = await adapter.knownLinks
            status = "Адаптер открыт, инициализация ЭБУ…"
            if techToFile { try? tech.start() }
            try await runProprietary(adapter)
        } catch {
            // Before the status, because the status is one line and this is
            // the part that says where it went wrong.
            openingReport = await adapter.openingReport
            if !Task.isCancelled {
                status = "Ошибка: \(error.localizedDescription)"
                state = .failed
            }
        }
        // Always release what this task itself owns.
        adapter.close()
        // But touch shared session state only if this task is still the current
        // session: a `disconnect` or a `connect` that has since happened owns it
        // now, and this task unwinding late must not stop its log or nil its loop.
        guard generation == runGeneration else { return }
        stopLogging()
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
        startLogging(keys: logKeys)
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
        lastFlush = Date()
        while !Task.isCancelled {
            cycle += 1
            let started = Date()
            var asked = 0
            var answered = false

            for (index, page) in profile.pages.enumerated() {
                if Task.isCancelled { break }
                // A page read less than every cycle is spread by its position,
                // so pages sharing a period do not all land on the same cycle
                // and clump the cost; dead ones get an occasional retry in case
                // the failure was transient.
                let period = periodOf(page)
                if period > 1, (cycle + Int64(index)) % Int64(period) != 0 { continue }
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

            // Write the accumulated log buffers out now and then, so a crash or
            // an app kill costs at most a few seconds rather than the whole drive.
            if Date().timeIntervalSince(lastFlush) >= Self.flushInterval {
                flushLog()
                lastFlush = Date()
            }
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
            recordedKeys = Set(keys)
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
        recordedKeys = []
    }

    /// Push what is buffered, so a file can be shared without stopping.
    func flushLog() {
        logger.flush()
        tech.flush()
    }

    // MARK: - on demand

    /// The engine's own identity, for the screens that now show it beside the
    /// other modules of the car rather than on its own.
    var engineName: String { profile.ecu }
    var engineRequest: String { profile.can.req }

    /// Walk the adapter's own module handles instead of the platform's CAN
    /// addresses, and see what answers on each.
    ///
    /// This is the second shape of the fault sweep, for an adapter that has no
    /// CAN identifiers at all. It cannot name a module: several modules answer
    /// the same recognition frames and only the address tells them apart. What
    /// it can do is say which handles are alive, what class of module each is,
    /// and what each one's fault memory holds - and record the identification
    /// bytes, which is what pairs a handle with an address once the same car
    /// has been swept over CAN.
    func probeLinks(_ scan: ScanProfile,
                    onProgress: (Int, Int, UInt16) -> Void,
                    onLink: (LinkProbe) -> Void) async throws {
        guard let adapter else { throw TransportError.notOpen }
        let links = await adapter.knownLinks
        guard !links.isEmpty else {
            throw SessionError.refused("У этого адаптера нет собственных каналов: "
                                       + "он адресует блоки по CAN, и обход идёт по адресам")
        }
        let classes = scan.recognitionClasses
        try await io.locked {
            for (i, link) in links.enumerated() {
                onProgress(i + 1, links.count, link)
                await adapter.applyHeader(ThinkDiagLink.header(for: link), receive: "")
                var probe = LinkProbe(link: link)
                for group in classes {
                    if !group.openSession.isEmpty, !group.openAnswer.isEmpty {
                        let answer = Frames.clean(
                            await self.at(adapter, group.openSession, 1.2))
                        guard answer.hasPrefix(String(group.openAnswer.prefix(2))) else {
                            continue
                        }
                    }
                    let reply = Frames.clean(await self.at(adapter, group.reco, 1.5))
                    guard reply.hasPrefix(group.recoAnswer) else { continue }
                    probe.reco = group.reco
                    probe.identHex = String(reply.dropFirst(group.recoAnswer.count))
                    probe.candidates = group.members
                    // The members of a class do not always read faults the same
                    // way, so try each layout and keep the first that answers.
                    for layout in group.faultLayouts {
                        do {
                            probe.faults = try await self.readFaults(layout, adapter)
                            probe.layout = layout
                            probe.failure = nil
                            break
                        } catch {
                            probe.failure = error.localizedDescription
                        }
                    }
                    break
                }
                onLink(probe)
            }
            await self.backToEngine(adapter)
        }
    }

    /// Walk the diagnostic addresses of the platform: point the adapter at each,
    /// open a session, ask the recognition frame, and read the fault memory of
    /// whatever answers.
    ///
    /// `fitted` narrows the walk to a car's own modules, as an earlier full
    /// sweep found them - the difference between a minute and a few seconds,
    /// since every address nothing sits on costs an adapter timeout.
    ///
    /// Several ECUs share one address and only one of them is fitted, so the
    /// candidates are tried in turn and the first that replies wins. Modules
    /// are handed back one at a time rather than all at the end: the walk pays
    /// an adapter timeout for every address nothing sits on, so the screen
    /// fills as it goes instead of holding a spinner for a minute. Everything
    /// runs under the poll loop's lock, so live values freeze for the duration.
    func scanFaults(_ scan: ScanProfile,
                    fitted: [String: String]? = nil,
                    onProbe: (Int, Int, String) -> Void,
                    onModule: (EcuNode) -> Void) async throws -> ScanSummary {
        guard let adapter else { throw TransportError.notOpen }
        let reachable = await adapter.addressableHeaders
        return try await io.locked {
            var summary = ScanSummary(full: fitted == nil)
            let addresses = fitted.map { scan.probes(fittedTo: $0) } ?? scan.byAddress
            for (i, entry) in addresses.enumerated() {
                onProbe(i + 1, addresses.count, entry.address)
                // A ThinkDiag speaks Launch's own framing and reaches only the
                // modules its capture proved; saying so beats reporting the
                // whole car as silent.
                guard reachable.isEmpty || reachable.contains(entry.address) else {
                    if let first = entry.targets.first { summary.unreachable.append(first) }
                    continue
                }
                guard let hit = await self.probe(entry.targets, adapter) else {
                    if let first = entry.targets.first { summary.silent.append(first) }
                    continue
                }
                var node = EcuNode(target: hit.target, identHex: hit.ident,
                                   faults: [], failure: nil)
                if let layout = hit.target.faults {
                    do {
                        node.faults = try await self.readFaults(layout, adapter)
                    } catch {
                        node.failure = error.localizedDescription
                    }
                }
                onModule(node)
            }
            await self.backToEngine(adapter)
            return summary
        }
    }

    /// Read the fault memory of one module on its own. The session opened
    /// during the sweep has long timed out, so this opens it again.
    func faults(of target: ScanProfile.Target) async throws -> [Dtc] {
        guard let layout = target.faults else { return [] }
        return try await withModule(target) { try await self.readFaults(layout, $0) }
    }

    /// Clear the whole fault memory of one module.
    func clearFaults(of target: ScanProfile.Target) async throws {
        guard let frame = target.clear else {
            throw SessionError.refused("стирание для этого блока не описано")
        }
        try await withModule(target) { try await self.clear(frame, $0) }
    }

    /// Clear one fault and leave the rest. It is the same service with the
    /// fault itself as the group of DTC instead of the "everything" group:
    /// `14 <code>` on a KWP module, `14 <code> <failure type>` on a UDS one,
    /// whose groups are three bytes wide.
    ///
    /// Not every ECU accepts a single fault there; one that does not answers
    /// `7F 14 31` and the refusal is passed on as it came.
    func clear(_ dtc: Dtc, of target: ScanProfile.Target) async throws {
        guard target.clear != nil else {
            throw SessionError.refused("стирание для этого блока не описано")
        }
        var frame = "14" + dtc.code
        if target.clearGroupBytes >= 3 {
            frame += dtc.failureType.isEmpty ? "00" : dtc.failureType
        }
        try await withModule(target) { try await self.clear(frame, $0) }
    }

    // MARK: -

    /// Try the candidates of one address in turn, stopping at the first that
    /// answers both the session frame and the recognition frame.
    private func probe(_ candidates: [ScanProfile.Target],
                       _ adapter: any Adapter) async
        -> (target: ScanProfile.Target, ident: String)? {
        guard let first = candidates.first else { return nil }
        await point(adapter, at: first)
        for target in candidates {
            if !target.openSession.isEmpty, !target.openAnswer.isEmpty {
                let answer = Frames.clean(await at(adapter, target.openSession, 1.2))
                guard answer.hasPrefix(String(target.openAnswer.prefix(2))) else { continue }
            }
            let reply = Frames.clean(await at(adapter, target.reco, 1.5))
            guard reply.hasPrefix(target.recoAnswer) else { continue }
            return (target, String(reply.dropFirst(target.recoAnswer.count)))
        }
        return nil
    }

    /// Point the adapter at one module: the header pair, and the flow-control
    /// header that goes with it. Without the second one a multi-frame answer
    /// from anything but the engine is never assembled - the adapter would
    /// send its flow control to the engine's address.
    private func point(_ adapter: any Adapter, at target: ScanProfile.Target) async {
        await adapter.applyHeader(target.request, receive: target.response)
        await at(adapter, "ATFCSH" + target.request, 0.6)
    }

    /// Put the adapter back where the poll loop expects it - and re-open the
    /// engine's diagnostic session while doing so. A sweep spends a minute
    /// talking to other modules, by the end of which the engine has dropped
    /// the session `81` opened, and without it the proprietary pages answer
    /// nothing at all. The loop does have a `reopen` path, but it costs
    /// several mute cycles before it fires; this costs one command.
    private func backToEngine(_ adapter: any Adapter) async {
        await adapter.applyHeader(profile.can.req, receive: profile.can.res)
        await at(adapter, "ATFCSH" + profile.can.req, 0.6)
        await at(adapter, "81", 2.5, note: "после опроса блоков")
    }

    /// One module at a time, with the adapter handed back to the poll loop
    /// however it ends.
    private func withModule<T>(_ target: ScanProfile.Target,
                               _ body: (any Adapter) async throws -> T) async throws -> T {
        guard let adapter else { throw TransportError.notOpen }
        return try await io.locked {
            do {
                await self.point(adapter, at: target)
                if !target.openSession.isEmpty {
                    await self.at(adapter, target.openSession, 1.2)
                }
                let value = try await body(adapter)
                await self.backToEngine(adapter)
                return value
            } catch {
                await self.backToEngine(adapter)
                throw error
            }
        }
    }

    /// Read the fault memory of the module the adapter is already pointed at.
    ///
    /// The poll loop runs the adapter on a 100 ms timeout, which is right for
    /// a page and far too short for a fault list that can run to several
    /// frames, so the timeout goes back to the ELM default for this exchange
    /// and returns to the loop's afterwards.
    private func readFaults(_ layout: ScanProfile.FaultFrames,
                            _ adapter: any Adapter) async throws -> [Dtc] {
        await at(adapter, "ATSTFF", 0.6)
        let reply = await at(adapter, layout.request, 3.0)
        await at(adapter, "ATST" + Self.pollST, 0.6)
        return try Self.parseFaults(reply, layout)
    }

    private func clear(_ frame: String, _ adapter: any Adapter) async throws {
        await at(adapter, "ATSTFF", 0.6)
        let clean = Frames.clean(await at(adapter, frame, 4.0))
        await at(adapter, "ATST" + Self.pollST, 0.6)
        guard clean.hasPrefix("54") else {
            if let why = Frames.negativeResponse(clean) { throw SessionError.refused(why) }
            throw SessionError.notCleared(clean.isEmpty ? "нет ответа" : String(clean.prefix(24)))
        }
    }

    /// Split out of the reads so the parsing can be tested without an adapter.
    static func parseFaults(_ reply: String,
                            _ layout: ScanProfile.FaultFrames) throws -> [Dtc] {
        if Frames.isError(reply) { throw SessionError.noAnswer(layout.request) }
        let clean = Frames.clean(reply)
        guard clean.hasPrefix(layout.answer) else {
            if let why = Frames.negativeResponse(clean) { throw SessionError.refused(why) }
            throw SessionError.unexpected(clean.isEmpty ? "нет ответа" : String(clean.prefix(24)))
        }
        return Frames.dtcRecords(clean, layout)
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
    /// The ECU answered, and the answer was "no". Carries its own sentence,
    /// because a negative response code says why and the why is the whole
    /// difference between a module that cannot do it and one that will not
    /// right now.
    case refused(String)

    var errorDescription: String? {
        switch self {
        case let .noAnswer(what):
            return "Нет ответа на \(what)"
        case let .unexpected(what):
            return "Неожиданный ответ: \(what)"
        case let .notCleared(what):
            return "ЭБУ не подтвердил стирание: \(what)"
        case let .refused(why):
            return why
        }
    }
}
