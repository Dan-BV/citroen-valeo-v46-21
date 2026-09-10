import XCTest

/// The ThinkDiag adapter driven end to end against a fake that speaks the real
/// protocol - the closest thing to the car that CI can hold.
///
/// The bytes on both sides are copied out of the 2026-09-10 capture: the
/// identity and version replies, the `27/01` request for engine page CB, and
/// the answer the engine gave to it. So this checks the two things the car will
/// check, and can fail here first: that the adapter puts exactly the captured
/// bytes on the wire, and that what comes back reaches the session in a form
/// `Frames` can read.
final class ThinkDiagAdapterTests: XCTestCase {

    // MARK: - the opening

    func testOpeningReadsTheIdentityAndReportsEveryStep() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()

        let identity = await adapter.identity
        XCTAssertEqual(identity.model, "diagmini")
        XCTAssertEqual(identity.firmware, "V1.00.000")
        XCTAssertEqual(identity.software, "V1.23.004")

        let report = await adapter.openingReport
        // Six queries, two script steps, then the line naming the adapter.
        XCTAssertEqual(report.count, 9, report.joined(separator: " | "))
        XCTAssertTrue(report[6].contains("лицензия"), report[6])
        XCTAssertTrue(report.last?.contains("diagmini") == true, report.last ?? "")
    }

    /// The instrument the first drive needs. Whether this adapter accepts a
    /// replayed activation response is unknown and can only be settled on the
    /// car; what makes that answerable in one attempt is the error naming the
    /// step it stopped at.
    func testAnAdapterThatGoesSilentNamesTheStepItStoppedAt() async {
        let fake = FakeThinkDiag()
        fake.silentAfter = 6            // answer the opening, then stop
        let adapter = ThinkDiagAdapter(transport: fake, script: script)

        do {
            try await adapter.open()
            XCTFail("a silent adapter must not open")
        } catch {
            XCTAssertEqual(error as? ThinkDiagError,
                           .stopped(step: "лицензия", number: 7, of: 8))
            XCTAssertEqual(error.localizedDescription,
                           "Адаптер молчит на шаге 7 из 8: «лицензия»")
        }

        let report = await adapter.openingReport
        XCTAssertTrue(report.last?.contains("нет ответа") == true, report.last ?? "")
    }

    /// The captured licence and activation frames were taken from one model of
    /// adapter. Replaying them at something else would be sending credentials
    /// into a device we have never observed.
    func testSomethingThatIsNotADiagMiniIsRefused() async {
        let fake = FakeThinkDiag()
        fake.model = "diagpro"
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        do {
            try await adapter.open()
            XCTFail("the wrong model must not open")
        } catch {
            XCTAssertEqual(error as? ThinkDiagError, .notDiagMini("diagpro"))
        }
    }

    /// The drive of 2026-09-10 stopped at `21/11` - one of three opening
    /// queries whose two-byte status nobody reads. Stopping there was the worse
    /// of the two guesses: carrying on either reaches the licence or fails
    /// there, and both outcomes say more than never having tried.
    func testSilenceOnAStatusQueryDoesNotStopTheOpening() async throws {
        let fake = FakeThinkDiag()
        fake.answers.removeValue(forKey: "11")
        let adapter = ThinkDiagAdapter(transport: fake, script: script)

        try await adapter.open()

        let report = await adapter.openingReport
        let joined = report.joined(separator: " | ")
        XCTAssertTrue(report.contains { $0.contains("запрос 11") && $0.contains("нет ответа") },
                      joined)
        XCTAssertTrue(report.contains { $0.contains("нет ответа и на повтор") }, joined)
        XCTAssertTrue(report.contains { $0.contains("лицензия") },
                      "it has to have got past the silence: \(joined)")
        XCTAssertTrue(report.last?.contains("diagmini") == true, joined)
    }

    /// Silence on an identity query is a different matter: without it there is
    /// no telling this adapter from any other device that answers `55aa`, and
    /// the licence is not something to send into an unknown box.
    func testSilenceOnAnIdentityQueryDoesStopTheOpening() async {
        let fake = FakeThinkDiag()
        fake.answers.removeValue(forKey: "03")
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        do {
            try await adapter.open()
            XCTFail("an unidentified adapter must not be sent the licence")
        } catch {
            XCTAssertEqual(error as? ThinkDiagError,
                           .stopped(step: "идентификация", number: 1, of: 8))
        }
    }

    /// The report has to say whether anything arrived at all. "No answer"
    /// covers two diagnoses with nothing in common - the adapter said nothing,
    /// or it answered and the frame was rejected - and the drive of 2026-09-10
    /// could not tell them apart.
    func testASilentStepReportsWhatTheLinkDelivered() async {
        let fake = FakeThinkDiag()
        fake.answers.removeValue(forKey: "1802aabb")
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try? await adapter.open()

        let last = await adapter.openingReport.last ?? ""
        XCTAssertTrue(last.contains("нет ответа и на повтор"), last)
        XCTAssertTrue(last.contains("0 увед."), last)
        XCTAssertTrue(last.contains("0 Б"), last)
    }

    /// An unexpected-but-present answer is a gap in what we know, not a fault.
    func testAnUnexpectedAnswerIsNotedAndTheOpeningCarriesOn() async throws {
        let fake = FakeThinkDiag()
        fake.answers["11"] = "1106"          // captured is `1100`
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()

        let report = await adapter.openingReport
        XCTAssertTrue(report[5].contains("неожиданный ответ 1106"), report[5])
    }

    // MARK: - a page

    /// The whole point, in one test: the session asks for engine page CB the
    /// way it always has, and the adapter puts the bytes the official app put
    /// on the wire, to the byte.
    func testAPageRequestIsTheCapturedBytes() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")
        fake.forget()

        _ = await adapter.send("21CB8001", 2.5)

        XCTAssertEqual(fake.sent.count, 1)
        XCTAssertEqual(fake.sent.first?.cmd, 0x27)
        XCTAssertEqual(fake.sent.first?.payload, Data(hex: pageCBRequest))
    }

    /// And the answer comes back in a form the session's `Frames` reads, with
    /// the marker where the field offsets are counted from.
    func testAPageAnswerReachesTheSessionAsReadableHex() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")

        let reply = await adapter.send("21C08001", 2.5)
        XCTAssertFalse(Frames.isError(reply), reply)

        let clean = Frames.clean(reply)
        XCTAssertEqual(clean, pageC0Answer.uppercased())
        XCTAssertTrue(clean.hasPrefix("61FF"), "the marker has to be at the front")
        XCTAssertEqual(Frames.extract(clean, marker: "61FF", offset: 2, length: 2), 0x02ec)
    }

    /// Accumulating an answer across notifications is the thing the ELM path
    /// never had to do, so it is worth proving through the actor and not only
    /// in the reader. Page C0 is 93 bytes framed, which is exactly this link's
    /// notification size, so the pieces are cut at twenty to force the case
    /// that 672 of the captured frames are in anyway.
    func testAnAnswerWiderThanOneNotificationIsAssembled() async throws {
        let fake = FakeThinkDiag()
        fake.chunk = 20                  // harsher than the real link
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")

        let reply = await adapter.send("21C08001", 2.5)
        XCTAssertEqual(Frames.clean(reply), pageC0Answer.uppercased())
    }

    /// A bare `01ff…` status is this adapter's way of saying the ECU did not
    /// answer, and the session already knows what to do with `NO DATA`.
    func testAStatusReplyBecomesNoData() async throws {
        let fake = FakeThinkDiag()
        fake.answers[pageCBRequest] = "01ff02"
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")

        let reply = await adapter.send("21CB8001", 2.5)
        XCTAssertTrue(Frames.isError(reply), reply)
        XCTAssertTrue(reply.contains("NO DATA"))
    }

    /// A page that goes unanswered is an empty reply, and a link that has died
    /// is `linkFailure`. Confusing the two is what spun the poll loop two
    /// thousand times a second on 2026-09-10, so it is worth a test on this
    /// adapter too.
    func testADeadLinkIsReportedRatherThanLookingLikeAQuietEcu() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")

        fake.failWritesWith = .disconnected
        let reply = await adapter.send("21CB8001", 2.5)
        XCTAssertEqual(reply, "", "an empty reply, not NO DATA")
        XCTAssertFalse(Frames.isError(reply), "and nothing that reads as an ECU refusal")
        let failure = await adapter.linkFailure
        XCTAssertEqual(failure, .disconnected)
        let stats = await adapter.lastStats
        XCTAssertEqual(stats, LinkStats(), "an exchange that never happened costs nothing")
    }

    // MARK: - the ELM vocabulary

    /// Fourteen configuration commands the session sends before it asks for
    /// anything. None of them means a thing here, and none of them may look
    /// like a fault in the log.
    func testConfigurationCommandsAreAcknowledgedWithoutTouchingTheLink() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        fake.forget()

        for command in ["ATD", "ATE0", "ATL0", "ATH0", "ATS0", "ATAL", "ATAT2",
                        "ATST19", "ATSP6", "ATFCSH6A8", "ATFCSD300000", "ATFCSM1"] {
            let reply = await adapter.send(command, 0.8)
            XCTAssertEqual(reply, "OK\r", command)
            XCTAssertFalse(Frames.isError(reply), command)
        }
        XCTAssertTrue(fake.sent.isEmpty, "not one of them belongs on the wire")
    }

    /// `ATZ` is the one with a truthful answer to give.
    func testResetAnswersWithWhatTheAdapterSaidItWas() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        let reply = await adapter.send("ATZ", 2.5)
        XCTAssertTrue(reply.contains("diagmini"), reply)
    }

    /// Where the ELM path pays two writes per module change, this pays none.
    func testPointingAtAModuleCostsNoExchange() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        fake.forget()

        await adapter.applyHeader("6A8", receive: "688")
        await adapter.applyHeader("6A8", receive: "688")
        XCTAssertTrue(fake.sent.isEmpty)
    }

    /// A handle is not derived from a CAN identifier, it is looked up - so a
    /// module the capture never showed cannot be addressed, and saying so is
    /// better than sending a request into the wrong one.
    func testAModuleWithNoKnownHandleIsRefusedAndNoted() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("752", receive: "652")
        fake.forget()

        let reply = await adapter.send("2180", 2.5)
        XCTAssertTrue(Frames.isError(reply), reply)
        XCTAssertTrue(fake.sent.isEmpty, "nothing may go out with no handle to name")

        let report = await adapter.openingReport
        XCTAssertTrue(report.contains { $0.contains("752") }, report.joined(separator: " | "))
    }

    func testSomethingThatIsNotHexIsRefusedRatherThanSent() async throws {
        let fake = FakeThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")
        fake.forget()

        let reply = await adapter.send("HELLO", 0.5)
        XCTAssertTrue(Frames.isError(reply), reply)
        XCTAssertTrue(fake.sent.isEmpty)
    }

    // MARK: - the measurement

    /// The technical log is how a change of adapter gets judged rather than
    /// assumed, so this adapter has to report the same three numbers.
    func testTheLinkCostIsReportedTheSameWay() async throws {
        let fake = FakeThinkDiag()
        fake.chunk = 20
        let adapter = ThinkDiagAdapter(transport: fake, script: script)
        try await adapter.open()
        await adapter.applyHeader("6A8", receive: "688")

        _ = await adapter.send("21C08001", 2.5)
        let stats = await adapter.lastStats
        XCTAssertEqual(stats.bytes, 93, "the framed reply")
        XCTAssertEqual(stats.notifications, 5, "93 bytes in twenty-byte pieces")
        XCTAssertEqual(stats.largest, 20)
    }

    // MARK: - fixtures

    /// The `27/01` payload the official app sent for engine page CB.
    private let pageCBRequest = "01640001ff020a61010529050421cb8001"

    /// What the engine answered to page C0, as the adapter should hand it on.
    private let pageC0Answer = """
        61ff02ec8f800108010801080108ffffffffffffffff00ff01ff0070ffff00ff00ff015f\
        ffff0361ffff03b6ffff83deffff83deffff0603e718ffffffffffffffffffffffffffff
        """

    /// Two steps standing in for the licence and activation, cut to four bytes
    /// each: the real ones are the adapter's credentials and stay local.
    private var script: ThinkDiagScript {
        ThinkDiagScript(
            application: "CITROEN V46.21", capturedAt: "2026-09-10", note: "fixture",
            steps: [
                .init(label: "лицензия", cmd: "21", payload: "1802aabb", expecting: nil),
                .init(label: "блок активации", cmd: "27", payload: "01602802ccdd",
                      expecting: "01ff00"),
            ])
    }
}

/// A ThinkDiag that answers from a table instead of from a car.
///
/// It speaks the real framing in both directions - parsing what the adapter
/// writes and answering with `cmd | 0x40` and the same sequence id - so the
/// codec, the reader and the actor are all exercised rather than mocked out.
private final class FakeThinkDiag: LinkTransport {

    /// Request payload hex to reply payload hex. Seeded with the captured
    /// answers; a test overwrites the one it is interested in.
    var answers: [String: String]

    /// What `21/05` says its model is.
    var model = "diagmini"

    /// Notification size. The real link delivers 93 bytes; the tests use 20 to
    /// force reassembly.
    var chunk = 93

    /// Stop answering once this many exchanges have been answered.
    var silentAfter: Int?

    var failWritesWith: TransportError?

    private let lock = NSLock()
    private var frames: [ThinkDiagFrame] = []
    private var pending: [Data] = []
    private var link = LinkStats()
    private var answered = 0

    /// Every frame that was written, for a test to check against the capture.
    var sent: [ThinkDiagFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    init() {
        answers = [
            // The two descriptive replies, as captured.
            "03": """
                03001932653264353333353337333633363133346533383336333200000d3937393836\
                3534393730333700000a56312e30302e3030300000093230323630313330000003313300
                """,
            "2a": "2a00",
            "11": "1100",
            "1802aabb": "180200aabb08",
            "01602802ccdd": "01ff00",
            // Engine pages, as captured. Page C0 is 87 bytes of payload, so it
            // cannot arrive in one notification.
            "01640001ff020a61010529050421c08001": """
                0100000b55aa0b08d100104861ff02ec8f800108010801080108ffffffffffffffff00ff\
                01ff0070ffff00ff00ff015fffff0361ffff03b6ffff83deffff83deffff0603e718ffff\
                ffffffffffffffffffffffff
                """,
            "01640001ff020a61010529050421cb8001": """
                0100000955aa0b08d100103b61ff02ec8e5185ffffff00001a0000000102ffffff002601\
                f401f301f2ffffffffff01ffffff01004500ff24c2ffffffff00000000ffff016800d0
                """,
        ]
    }

    func forget() {
        lock.lock(); defer { lock.unlock() }
        frames = []
    }

    func open() async throws {}
    func close() {}

    func write(_ data: Data) async throws {
        if let failure = failWritesWith { throw failure }

        // Whatever arrives is parsed with the real reader, so a fake that is
        // handed a malformed frame stays silent exactly as the adapter would.
        let reader = ThinkDiagFrameReader()
        reader.append(data)
        while let request = reader.next() {
            lock.lock()
            frames.append(request)
            let quiet = silentAfter.map { answered >= $0 } ?? false
            lock.unlock()
            if quiet { continue }

            guard let payload = reply(to: request) else { continue }
            let frame = ThinkDiagFrame(tag: .fromAdapter, seq: request.seq,
                                       cmd: request.cmd | ThinkDiagFrame.replyBit,
                                       payload: payload)
            lock.lock()
            answered += 1
            pending.append(contentsOf: Chunker.chunks(frame.encoded, size: chunk))
            lock.unlock()
        }
    }

    private func reply(to request: ThinkDiagFrame) -> Data? {
        let key = request.payload.hexString
        // `21/05` is built rather than looked up, so a test can change the
        // model without restating 42 bytes of version strings.
        if request.cmd == 0x21, key == "05" {
            var payload = Data([0x05])
            for text in ["V1.23.004", "V23.05", "V10.04", model] {
                var bytes = Data(text.utf8)
                bytes.append(0)
                payload.append(UInt8(bytes.count >> 8))
                payload.append(UInt8(bytes.count & 0xff))
                payload.append(bytes)
            }
            return payload
        }
        if request.cmd == 0x25, key == "05" { return Data(hex: "0500") }
        return answers[key].flatMap { Data(hex: $0) }
    }

    func readText(until terminator: Character, timeout: TimeInterval) async -> String {
        String(decoding: await readBytes(timeout: timeout), as: UTF8.self)
    }

    func readBytes(timeout: TimeInterval) async -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return Data() }
        let piece = pending.removeFirst()
        link.notifications += 1
        link.bytes += piece.count
        link.largest = max(link.largest, piece.count)
        return piece
    }

    func drain() {
        lock.lock(); defer { lock.unlock() }
        pending = []
        link = LinkStats()
    }

    var stats: LinkStats {
        lock.lock(); defer { lock.unlock() }
        return link
    }
}
