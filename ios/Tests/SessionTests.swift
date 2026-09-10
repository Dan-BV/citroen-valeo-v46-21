import XCTest

/// A transport that answers from a script instead of from an adapter, so the
/// session can be driven end to end - init, page probe, poll loop, fault codes
/// - without a car.
final class ScriptedTransport: LinkTransport {
    /// Command without the carriage return, to the reply the adapter would
    /// give. Anything not listed answers `OK`, like an ELM327 does for AT
    /// commands it accepts.
    var script: [String: String] = [:]
    private(set) var sent: [String] = []
    private let lock = NSLock()
    private var pending = ""
    private var link = LinkStats()

    var opened = false
    var closed = false
    var failOpenWith: TransportError?

    func open() async throws {
        if let failure = failOpenWith { throw failure }
        opened = true
    }

    func write(_ data: Data) async throws {
        let command = String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        sent.append(command)
        pending = (script[command] ?? "OK") + "\r>"
        link = LinkStats(notifications: 1, bytes: pending.utf8.count,
                         largest: pending.utf8.count)
        lock.unlock()
    }

    func readText(until terminator: Character, timeout: TimeInterval) async -> String {
        lock.lock(); defer { lock.unlock() }
        let reply = pending
        pending = ""
        return reply
    }

    /// This script is ELM327 text, so the byte read hands the same reply over
    /// unconverted. Nothing here uses it; it exists because the protocol has it.
    func readBytes(timeout: TimeInterval) async -> Data {
        lock.lock(); defer { lock.unlock() }
        let reply = pending
        pending = ""
        return Data(reply.utf8)
    }

    func drain() {
        lock.lock(); defer { lock.unlock() }
        pending = ""
        link = LinkStats()
    }

    /// One notification per reply, which is what a scripted adapter is.
    var stats: LinkStats {
        lock.lock(); defer { lock.unlock() }
        return link
    }

    func close() {
        closed = true
    }
}

@MainActor
final class SessionTests: XCTestCase {

    private var bundle: Bundle { Bundle(for: SessionTests.self) }

    private func loadProfile() throws -> Profile {
        try Profile.bundled(in: bundle)
    }

    /// One real recorded frame per page, taken from the parity fixture so the
    /// session test and the decoder test cannot disagree about what a frame
    /// means.
    private func recordedFrames() throws -> [String: String] {
        struct Golden: Decodable {
            struct Sample: Decodable {
                let p: String
                let h: String
            }
            let samples: [Sample]
        }
        let url = try XCTUnwrap(bundle.url(forResource: "golden", withExtension: "json"))
        let golden = try JSONDecoder().decode(Golden.self, from: try Data(contentsOf: url))
        var first: [String: String] = [:]
        for sample in golden.samples where first[sample.p] == nil {
            first[sample.p] = sample.h
        }
        return first
    }

    private func scripted(_ profile: Profile) throws -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.script["ATZ"] = "ELM327 v1.5"
        let frames = try recordedFrames()
        for page in profile.pages {
            if let id = page.id, let frame = frames[id] {
                transport.script[page.request] = frame
            } else {
                // A page the recording does not cover answers like a page this
                // ECU variant does not implement.
                transport.script[page.request] = "NO DATA"
            }
        }
        return transport
    }

    private func makeSession(_ profile: Profile,
                             _ transport: ScriptedTransport) -> ElmSession {
        ElmSession(profile: profile, makeTransport: { _ in transport })
    }

    private func settle(_ until: () -> Bool, _ seconds: TimeInterval = 10,
                        _ what: String) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if until() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - the session

    func testTheEcuSessionOpensAndPollsRecordedFrames() async throws {
        let profile = try loadProfile()
        let transport = try scripted(profile)
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ session.state == .connected }, 10, "the session to open")
        try await settle({ !session.values.isEmpty }, 10, "the first values")

        // The opening sequence must be exactly the Kotlin one: the 21xx pages
        // answer nothing without `81`, and ATSP6 picks 11-bit 500k CAN.
        let sent = transport.sent
        for command in ["ATZ", "ATE0", "ATSP6", "ATSH6A8", "ATCRA688",
                        "ATFCSH6A8", "ATFCSD300000", "ATFCSM1", "81"] {
            XCTAssertTrue(sent.contains(command), "\(command) was never sent")
        }
        XCTAssertLessThan(sent.firstIndex(of: "81") ?? .max,
                          sent.firstIndex(of: "21C08001") ?? 0,
                          "the session has to be opened before a page is asked for")

        // Pages the recording does not cover answered NO DATA, so the probe
        // must have written them off - and the ones it does cover must not be.
        XCTAssertTrue(session.deadPages.contains("21B08001"))
        XCTAssertFalse(session.deadPages.contains("21C08001"))

        // A value from a covered page, checked against the fixture's own frame.
        let page = try XCTUnwrap(profile.pages.first { $0.id == "C0" })
        let field = try XCTUnwrap(page.params.first)
        let frame = try XCTUnwrap(try recordedFrames()["C0"])
        let (raw, _) = try XCTUnwrap(field.read(Frames.clean(frame), marker: page.marker))
        let sample = try XCTUnwrap(session.values[field.key])
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.raw, raw)
        XCTAssertEqual(sample.value, field.value(fromMasked: raw), accuracy: 1e-9)

        session.disconnect()
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(session.state, .disconnected)
    }

    /// The header is only re-sent when it actually changes - it costs two
    /// adapter turnarounds, which is a page's worth of cycle time.
    func testTheCanHeaderIsSetOnceForAWholeCycle() async throws {
        let profile = try loadProfile()
        let transport = try scripted(profile)
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ !session.values.isEmpty }, 10, "the first values")
        session.disconnect()

        XCTAssertEqual(transport.sent.filter { $0 == "ATSH6A8" }.count, 1)
    }

    func testAFailingAdapterLeavesTheSessionInError() async throws {
        let profile = try loadProfile()
        let transport = ScriptedTransport()
        transport.failOpenWith = .noElmCharacteristics
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ session.state == .failed }, 10, "the failure")
        XCTAssertTrue(session.status.contains("не похоже на ELM327"))
    }

    /// An ECU that answers the AT commands but no page at all is not a working
    /// connection - most often the ignition is off.
    func testAnEcuThatAnswersNoPageIsNotConnected() async throws {
        let profile = try loadProfile()
        let transport = ScriptedTransport()
        transport.script["ATZ"] = "ELM327 v1.5"
        for page in profile.pages {
            transport.script[page.request] = "NO DATA"
        }
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ session.state == .failed }, 10, "the failure")
        XCTAssertTrue(session.status.contains("ЭБУ не отвечает"))
    }

    // MARK: - reading on demand, while the loop runs

    /// Exercises the lock as much as the parsing: the poll loop is running, and
    /// the two must not interleave commands on the one adapter.
    func testFaultCodesAreReadWhileThePollLoopRuns() async throws {
        let profile = try loadProfile()
        let transport = try scripted(profile)
        transport.script["17FF00"] = "5702007108123420"
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ !session.values.isEmpty }, 10, "the loop to be running")

        let faults = try await session.readDtc()
        XCTAssertEqual(faults.map(\.code), ["0071", "1234"])
        XCTAssertEqual(faults.map(\.status), ["08", "20"])
        XCTAssertEqual(faults[0].label, profile.dtc["0071"],
                       "the description comes from the profile's own 291 codes")
        session.disconnect()
    }

    func testClearingIsRefusedWhenTheEcuDoesNotConfirm() async throws {
        let profile = try loadProfile()
        let transport = try scripted(profile)
        transport.script["14FF00"] = "7F1478"   // a negative response
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ !session.values.isEmpty }, 10, "the loop to be running")

        do {
            try await session.clearDtc()
            XCTFail("a negative response must not read as success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("не подтвердил"))
        }
        session.disconnect()
    }

    func testClearingSucceedsOnTheServiceAcknowledgement() async throws {
        let profile = try loadProfile()
        let transport = try scripted(profile)
        transport.script["14FF00"] = "54"
        let session = makeSession(profile, transport)

        session.connect(.ble(id: UUID(), name: "scripted"))
        try await settle({ !session.values.isEmpty }, 10, "the loop to be running")
        try await session.clearDtc()
        session.disconnect()
    }

    /// Identification fields are packed digits, not measurements: they have to
    /// come out as the hex the official tool prints, or they cannot be compared
    /// with a Diagbox printout at all.
    func testIdentificationFieldsAreShownAsHexDigits() throws {
        let profile = try loadProfile()
        let block = try XCTUnwrap(profile.ident.first { $0.request == "2180" })
        let reference = try XCTUnwrap(block.params.first { $0.key == "ID_REFERENCE_MATERIEL" })
        XCTAssertEqual(reference.hex, true)

        // marker, then a byte per offset; the reference sits at 2 and is 5 long
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x61
        bytes[1] = 0x80
        for (i, byte) in [0x96, 0x66, 0x53, 0x90, 0x80].enumerated() {
            bytes[reference.offset + i] = UInt8(byte)
        }
        let frame = bytes.map { String(format: "%02X", $0) }.joined()

        let rows = ElmSession.identRows(of: block, in: frame)
        let shown = try XCTUnwrap(rows.first { $0.0 == reference.label }?.1)
        XCTAssertEqual(shown, "9666539080")
    }

    func testAnIdentificationBlockTheEcuDoesNotAnswerIsSkipped() throws {
        let profile = try loadProfile()
        let block = try XCTUnwrap(profile.ident.first)
        XCTAssertTrue(ElmSession.identRows(of: block, in: "").isEmpty)
    }

    // MARK: - fault codes

    func testFaultCodesAreParsedWithTheirDescriptions() throws {
        let profile = try loadProfile()
        let code = try XCTUnwrap(profile.dtc.keys.sorted().first)
        let reply = "57 01 " + code + " 08\r>"

        let faults = try ElmSession.parseDtc(reply, dictionary: profile.dtc)
        XCTAssertEqual(faults.count, 1)
        XCTAssertEqual(faults[0].code, code)
        XCTAssertEqual(faults[0].status, "08")
        XCTAssertEqual(faults[0].label, profile.dtc[code])
    }

    func testAnEmptyFaultMemoryReadsAsNoFaults() throws {
        XCTAssertEqual(try ElmSession.parseDtc("5700\r>", dictionary: [:]).count, 0)
    }

    /// A count larger than the frame must not be trusted: a truncated reply
    /// would otherwise read past its end.
    func testATruncatedFaultListStopsAtTheEndOfTheFrame() throws {
        let faults = try ElmSession.parseDtc("5703007108\r>", dictionary: [:])
        XCTAssertEqual(faults.count, 1)
        XCTAssertEqual(faults[0].code, "0071")
    }

    func testAnErrorReplyToTheFaultRequestThrows() {
        XCTAssertThrowsError(try ElmSession.parseDtc("NO DATA\r>", dictionary: [:])) { error in
            XCTAssertEqual(error as? SessionError, .noAnswer("17FF00"))
        }
    }

    func testAWrongServiceIdInTheFaultReplyThrows() {
        XCTAssertThrowsError(try ElmSession.parseDtc("7F1712\r>", dictionary: [:])) { error in
            guard case .unexpected = error as? SessionError else {
                return XCTFail("expected an unexpected-answer error, got \(error)")
            }
        }
    }
}
