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
    @Published private(set) var values: [String: Sample] = [:]
    /// Requests of pages the ECU did not answer when probed.
    @Published private(set) var deadPages: Set<String> = []

    // MARK: -

    private let profile: Profile
    private let makeTransport: (TransportConfig) -> any ElmTransport

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
    /// cycle. Starts as everything, like the Kotlin session.
    private var selected: Set<String>

    private var skip: Set<String> = []
    private var cycle: Int64 = 0

    /// Adapter reply timeout, in ELM units of 4 ms: 0x19 = 100 ms. The default
    /// is 0x32 (200 ms) and the ceiling 0xFF (1020 ms); with adaptive timing on
    /// this is the cap, not the usual wait.
    private static let pollST = "19"

    /// Cycles between reads of a page the profile marks static.
    private static let slowPeriod = 10

    /// Pages worth logging but not worth a request every pass. Mirrors
    /// BaseSet.PERIODS in the Android app - $C4 torque every second cycle,
    /// $CB engine environment every third.
    private static let periods: [String: Int] = ["C4": 2, "CB": 3]

    var isConnected: Bool { state == .connected }
    var isBusy: Bool { loop != nil }

    init(profile: Profile,
         makeTransport: @escaping (TransportConfig) -> any ElmTransport) {
        self.profile = profile
        self.makeTransport = makeTransport
        self.selected = Set(profile.pages.flatMap { $0.params.map(\.key) })
    }

    // MARK: - selection

    func setSelection(_ keys: Set<String>) { selected = keys }

    private func isOn(_ field: Profile.Field) -> Bool { selected.contains(field.key) }

    private func anyOn(_ page: Profile.Page) -> Bool { page.params.contains(where: isOn) }

    /// Cycles between reads of a page. The profile marks the two static pages
    /// `slow`.
    func periodOf(_ page: Profile.Page) -> Int {
        if page.slow == true { return Self.slowPeriod }
        return Self.periods[page.id ?? ""] ?? 1
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

            let alive = try await io.locked { await self.initEcu(adapter) }
            guard alive else {
                status = "ЭБУ не отвечает (адаптер / зажигание)"
                state = .failed
                adapter.close()
                loop = nil
                return
            }

            state = .connected
            status = "Проверка доступных страниц…"
            let dead = try await io.locked { await self.probePages(adapter) }
            deadPages = dead
            status = "Подключено" + (dead.isEmpty ? "" : " · без ответа: \(dead.count)")

            await pollLoop(adapter)
        } catch {
            if !Task.isCancelled {
                status = "Ошибка: \(error.localizedDescription)"
                state = .failed
            }
        }
        adapter.close()
        loop = nil
    }

    private func initEcu(_ adapter: Adapter) async -> Bool {
        await adapter.send("ATZ", 2.5)
        for command in ["ATD", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL"] {
            await adapter.send(command, 0.8)
        }
        // After a reply is assembled the adapter still sits waiting in case a
        // second module answers, and that wait - not the CAN traffic - is most
        // of a page's cost. Nothing else can answer here: ATCRA688 filters to
        // this ECU. AT2 lets the adapter shorten the wait to what the ECU
        // actually takes, ATST caps what it may wait when it guesses wrong.
        // If a page starts reading NO DATA, raise pollST before blaming it.
        await adapter.send("ATAT2", 0.8)
        await adapter.send("ATST" + Self.pollST, 0.8)
        await adapter.send("ATSP6", 0.8)
        await adapter.applyHeader(profile.can.req, receive: profile.can.res)
        await adapter.send("ATFCSH" + profile.can.req, 0.8)
        await adapter.send("ATFCSD300000", 0.8)
        await adapter.send("ATFCSM1", 0.8)
        await adapter.send("81", 2.5)

        // Consider the ECU reachable if any of the first few pages answers - a
        // single page can be one this variant does not implement, and that is
        // not a reason to call the whole connection dead.
        for page in profile.pages.prefix(3) {
            let reply = await adapter.send(page.request, 2.5)
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
        let reply = await adapter.send(page.request, 1.5)
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
                        return await adapter.send(page.request, 1.2)
                    }
                } catch {
                    break
                }
                let now = Date()
                lastMs[page.request] = Int(now.timeIntervalSince(sent) * 1000)
                lastReply[page.request] = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if Frames.isError(reply) { continue }
                skip.remove(page.request)

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
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            status = "Подключено · цикл \(elapsed) мс"
            await keepAliveIfIdle(adapter)
        }
    }

    private func keepAliveIfIdle(_ adapter: Adapter) async {
        guard await adapter.idleFor() > 2.5 else { return }
        _ = try? await io.locked { await adapter.send("3E", 0.8) }
    }

    // MARK: - on demand

    /// `17 FF 00` -> `57 <count> [ code(2) status(1) ] x count`.
    func readDtc() async throws -> [Dtc] {
        guard let adapter else { throw TransportError.notOpen }
        return try await io.locked {
            await adapter.applyHeader(self.profile.can.req, receive: self.profile.can.res)
            let reply = await adapter.send("17FF00", 3.0)
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
            let clean = Frames.clean(await adapter.send("14FF00", 3.0))
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
                let reply = await adapter.send(block.request, 2.5)
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
        return await transport.read(until: ">", timeout: timeout)
    }
}
