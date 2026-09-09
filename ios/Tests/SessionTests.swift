import XCTest

/// A transport that answers from a script instead of from an adapter, so the
/// session can be driven end to end - init, page probe, poll loop, fault codes
/// - without a car.
final class ScriptedTransport: ElmTransport {
    /// Command without the carriage return, to the reply the adapter would
    /// give. Anything not listed answers `OK`, like an ELM327 does for AT
    /// commands it accepts.
    var script: [String: String] = [:]
    private(set) var sent: [String] = []
    private let lock = NSLock()
    private var pending = ""

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
        lock.unlock()
    }

    func read(until terminator: Character, timeout: TimeInterval) async -> String {
        lock.lock(); defer { lock.unlock() }
        let reply = pending
        pending = ""
        return reply
    }

    func drain() {
        lock.lock(); defer { lock.unlock() }
        pending = ""
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
