import Foundation

/// A ThinkDiag driven through the same seam an ELM327 clone is.
///
/// `ElmSession` speaks a finite ELM327 vocabulary, and this interprets it
/// rather than forwarding it:
///
/// - the **AT commands** are ELM327 configuration a ThinkDiag has no
///   equivalent for, and are acknowledged without touching the link;
/// - **`applyHeader`** picks a link handle instead of writing a CAN header,
///   which costs no exchange at all where the ELM path costs two;
/// - **everything else** is a hex request, and rides `27/01`.
///
/// The session does not know which of the two it is talking to, and that is
/// the point of `Adapter` being a protocol.
actor ThinkDiagAdapter: Adapter {

    /// The ELM327 CAN request header, to the handle this adapter knows the
    /// same module by.
    ///
    /// One entry, because one is all the capture proves. A handle is not a CAN
    /// identifier and cannot be derived from one: no CAN identifier crosses
    /// this wire at all, the identifiers living inside the vehicle software
    /// the adapter downloaded. So this table can only ever grow by observing
    /// the official app address a module we care about.
    static let links: [String: UInt16] = ["6A8": ThinkDiagRequest.engineLink]

    /// Long enough for the licence step, which is 1629 bytes going out in
    /// twenty-byte writes with a pause between each - about 650 ms of pauses
    /// before the adapter has even read it all.
    static let handshakeTimeout: TimeInterval = 5

    /// For the three opening queries whose answer nobody reads. Every capture
    /// has them answering in milliseconds, and silence on one no longer ends
    /// the opening, so waiting long for them only delays the connect.
    static let statusTimeout: TimeInterval = 1.5

    /// What an ELM327 prints when the ECU says nothing, and what the session's
    /// `Frames.isError` already knows how to read. The equivalent here is a
    /// bare `01ff…` status reply.
    static let noData = "NO DATA\r"

    private let transport: any LinkTransport
    private let script: ThinkDiagScript?

    private var sequence = ThinkDiagSequence()
    private let reader = ThinkDiagFrameReader()
    private var header: String?
    private var link: UInt16?
    private var lastCommand = Date.distantPast

    private(set) var identity = ThinkDiagIdentity()
    private(set) var lastStats = LinkStats()
    private(set) var lastMs = 0
    private(set) var linkFailure: TransportError?

    /// How the opening went, step by step.
    ///
    /// This is the instrument the first drive needs. Two things about this
    /// adapter are unknown and can only be settled on the car - whether it
    /// accepts a replayed activation response, and whether the engine handle
    /// works once the prologue is through - and in both cases the useful
    /// evidence is the same: which step it stopped answering at.
    private(set) var openingReport: [String] = []

    init(transport: any LinkTransport, script: ThinkDiagScript?) {
        self.transport = transport
        self.script = script
    }

    // MARK: - Adapter

    func open() async throws {
        try await transport.open()
        try await performOpening()
    }

    nonisolated func close() {
        transport.close()
    }

    func idleFor() -> TimeInterval {
        Date().timeIntervalSince(lastCommand)
    }

    /// Free, unlike the ELM path's two writes: pointing this adapter at a
    /// module is choosing which handle the next request names.
    func applyHeader(_ header: String, receive: String) async {
        let wanted = header.uppercased()
        guard self.header != wanted else { return }
        self.header = wanted
        link = Self.links[wanted]
        if link == nil {
            openingReport.append("заголовок \(wanted): нет известного канала адаптера")
        }
    }

    @discardableResult
    func send(_ command: String, _ timeout: TimeInterval) async -> String {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("AT") { return acknowledge(text) }

        // `?` is what an ELM327 answers a command it cannot carry out, and
        // `Frames.isError` already reads it as one. Both cases here are that:
        // a module we have no handle for, and something that is not hex.
        guard let link else { return "?\r" }
        guard let request = Data(hex: text),
              let payload = ThinkDiagRequest.payload(link: link, request: request)
        else { return "?\r" }

        let frame = ThinkDiagFrame.request(seq: sequence.next(), cmd: 0x27, payload: payload)
        guard let reply = await exchange(frame, timeout: timeout) else { return "" }
        if ThinkDiagRequest.isStatus(reply.payload) { return Self.noData }
        guard let answer = ThinkDiagRequest.answer(in: reply.payload) else { return Self.noData }
        // Hex text, because that is what the session's `Frames` reads. The
        // answer is handed over whole, marker and all, and the field offsets
        // are counted from the marker exactly as on the ELM path.
        return answer.hexString.uppercased() + "\r"
    }

    // MARK: - the opening

    private func performOpening() async throws {
        let plan = try ThinkDiagHandshake.plan(with: script)
        openingReport = []
        for (index, step) in plan.enumerated() {
            var result = await attempt(step)
            // One retry, and only after silence. It is what tells a dead step
            // apart from a flaky one, and on the drive of 2026-09-10 the
            // report could say neither.
            if result.isFailure {
                openingReport.append("\(index + 1). \(step.label): нет ответа — \(evidence())")
                result = await attempt(step)
            }

            switch result {
            case let .answered(payload):
                openingReport.append("\(index + 1). \(step.label): \(payload.count) Б, \(lastMs) мс")
            case let .unexpected(payload):
                // Not a failure. The expectations come from three sessions
                // with one adapter, so an answer we did not predict is far
                // more likely to be a gap in what we know.
                openingReport.append("\(index + 1). \(step.label): неожиданный ответ "
                                     + payload.hexString)
            case .silent:
                openingReport.append("\(index + 1). \(step.label): нет ответа и на повтор — "
                                     + evidence())
                guard !step.required else {
                    throw ThinkDiagError.stopped(step: step.label,
                                                 number: index + 1, of: plan.count)
                }
                // Not required: carry on and find out what the licence does.
                continue
            }

            if index == ThinkDiagHandshake.identityStep, let payload = result.payload {
                _ = identity.readIdentity(payload)
            }
            if index == ThinkDiagHandshake.versionStep, let payload = result.payload {
                _ = identity.readVersions(payload)
            }
        }

        // Checked last, so the report above survives to say how far it got.
        guard identity.isDiagMini else { throw ThinkDiagError.notDiagMini(identity.model) }
        openingReport.append("адаптер: " + identity.summary)

        // Last of all. Without a script the six queries above still ran, and
        // what they proved is worth keeping: the adapter is the right one and
        // this link does carry `55aa`. Only then say what is missing.
        guard script != nil else { throw ThinkDiagError.noScript }
    }

    private func attempt(_ step: ThinkDiagStep) async -> ThinkDiagStepResult {
        // A status query answered in milliseconds in every capture, and now
        // that silence on one is survivable there is no sense waiting five
        // seconds for it twice. The licence steps keep the long timeout: a
        // 1629-byte write is 650 ms of inter-chunk pauses before the adapter
        // has even finished reading it.
        let timeout = step.required ? Self.handshakeTimeout : Self.statusTimeout
        let request = step.frame(seq: sequence.next())
        let reply = await exchange(request, timeout: timeout)
        return ThinkDiagHandshake.judge(step, request: request, reply: reply)
    }

    /// What the link actually delivered for the exchange just finished.
    ///
    /// This exists because of the drive of 2026-09-10, where the opening
    /// stopped at `21/11` and the report said only "нет ответа" - which covers
    /// two diagnoses that have nothing in common. Nothing arriving means the
    /// adapter did not answer. Bytes arriving and being discarded means it did
    /// answer and we rejected the frame, which would be our bug and not its
    /// behaviour. One line separates them.
    private func evidence() -> String {
        var parts = ["\(lastMs) мс",
                     "\(lastStats.notifications) увед.",
                     "\(lastStats.bytes) Б"]
        if lastStats.largest > 0 { parts.append("макс \(lastStats.largest) Б") }
        if reader.discarded > 0 { parts.append("отброшено \(reader.discarded) Б") }
        if reader.pending > 0 { parts.append("недособрано \(reader.pending) Б") }
        if let linkFailure { parts.append("связь: \(linkFailure.localizedDescription)") }
        return parts.joined(separator: ", ")
    }

    /// The AT vocabulary, which is all ELM327 configuration - echo, headers,
    /// spaces, timing, protocol selection, flow control. A ThinkDiag has none
    /// of it to configure: its own vehicle software decides all of that.
    ///
    /// `OK` rather than `?`, deliberately. `?` is a failure to
    /// `Frames.isError`, and it would make each of the session's fourteen
    /// configuration commands look like a fault in the technical log. They are
    /// not faults; they are questions that do not apply here.
    private func acknowledge(_ command: String) -> String {
        lastStats = LinkStats()
        lastMs = 0
        if command == "ATZ" || command == "ATI" {
            // The one AT command with a truthful answer to give.
            return identity.summary + "\r"
        }
        return "OK\r"
    }

    // MARK: - one exchange

    /// Write one frame and wait for the frame that answers it.
    ///
    /// The drain and the reset are not optional, for the same reason
    /// `ElmAdapter` drains: anything still buffered belongs to an earlier
    /// exchange, and read as this one's answer it would hand the previous
    /// page's data to every page after it.
    private func exchange(_ request: ThinkDiagFrame,
                          timeout: TimeInterval) async -> ThinkDiagFrame? {
        transport.drain()
        reader.reset()

        let attempted = Date()
        do {
            try await transport.write(request.encoded)
        } catch {
            linkFailure = error as? TransportError ?? .notOpen
            // Truthful numbers for the log: this exchange never happened. And
            // it must not look like an unanswered page, or the poll loop spins
            // on a dead link - which cost a drive on 2026-09-10.
            lastMs = Int(Date().timeIntervalSince(attempted) * 1000)
            lastStats = LinkStats()
            return nil
        }
        lastCommand = Date()

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var answer: ThinkDiagFrame?
        while true {
            if let frame = matching(request) {
                answer = frame
                break
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let arrived = await transport.readBytes(timeout: left)
            if arrived.isEmpty { break }
            reader.append(arrived)
        }
        lastMs = Int(Date().timeIntervalSince(started) * 1000)
        lastStats = transport.stats
        return answer
    }

    /// The next whole frame that answers `request`, dropping any that does
    /// not. After a drain the only other thing that can arrive is a reply that
    /// missed its own timeout, and letting that through is exactly the mix-up
    /// the drain exists to prevent.
    private func matching(_ request: ThinkDiagFrame) -> ThinkDiagFrame? {
        while let frame = reader.next() {
            if frame.answers(request) { return frame }
        }
        return nil
    }
}

enum ThinkDiagError: LocalizedError, Equatable {
    case stopped(step: String, number: Int, of: Int)
    case notDiagMini(String)
    case noScript

    var errorDescription: String? {
        switch self {
        case let .stopped(step, number, total):
            return "Адаптер молчит на шаге \(number) из \(total): «\(step)»"
        case let .notDiagMini(model):
            return model.isEmpty
                ? "Адаптер не назвал свою модель"
                : "Это не ThinkDiag Mini, модель «\(model)»"
        case .noScript:
            return "Адаптер отвечает, но сценарий активации не импортирован — "
                + "загрузи его в настройках"
        }
    }
}
