import XCTest

/// Choosing the adapter type, and getting the activation script onto the
/// phone.
///
/// Two things here would break quietly. A stored `.ble` choice has to survive
/// the enum gaining a case, or every existing install loses its adapter on
/// update. And an activation file has to be checked when it is imported rather
/// than when the car is in front of you - the licence step is 525 bytes, and a
/// file wrong by one digit looks exactly like a file that is right.
final class ThinkDiagSetupTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thinkdiag-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ThinkDiagScriptStore.root = root
    }

    override func tearDownWithError() throws {
        ThinkDiagScriptStore.root = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - which adapter

    /// The migration that matters: `TransportConfig` gained a case, and a
    /// choice stored by an earlier build has to still decode. Encoded here as
    /// literal JSON on purpose - re-encoding today's enum would prove nothing
    /// about what is already on someone's phone.
    func testAnAdapterStoredBeforeTheThinkDiagCaseExistedStillDecodes() throws {
        let stored = """
            {"ble":{"id":"7B1A2C3D-4E5F-6789-ABCD-EF0123456789","name":"OBDII"}}
            """
        let config = try JSONDecoder().decode(TransportConfig.self,
                                              from: Data(stored.utf8))
        XCTAssertEqual(config, .ble(id: UUID(uuidString: "7B1A2C3D-4E5F-6789-ABCD-EF0123456789")!,
                                    name: "OBDII"))
        XCTAssertEqual(config.name, "OBDII")
    }

    func testBothKindsOfAdapterSurviveBeingStoredAndReadBack() throws {
        let defaults = UserDefaults(suiteName: "thinkdiag-tests-" + UUID().uuidString)!
        for config in [TransportConfig.ble(id: UUID(), name: "Vgate"), .thinkDiagMini] {
            AdapterStore.save(config, to: defaults)
            XCTAssertEqual(AdapterStore.load(defaults), config)
        }
    }

    /// The ThinkDiag is found by the name it advertises, not by a
    /// CoreBluetooth identifier - that identifier changes on every reinstall,
    /// and a SideStore resign is a reinstall.
    func testTheThinkDiagIsIdentifiedByItsAdvertisedName() {
        XCTAssertEqual(TransportConfig.thinkDiagMini, .thinkDiag(name: "9TFD20257708"))
        XCTAssertEqual(TransportConfig.thinkDiagMini.name, TransportConfig.thinkDiagName)
    }

    // MARK: - importing the script

    func testImportingKeepsTheScriptAndReportsWhatItHolds() throws {
        let source = try write(sampleJSON, named: "thinkdiag_script.json")
        let imported = try ThinkDiagScriptStore.importFile(at: source)

        XCTAssertEqual(imported.steps.count, 2)
        XCTAssertEqual(imported.summary, "CITROEN V46.21 · 2 шагов · 10 Б")

        // And it is still there on the next look, which is what the connect
        // path relies on.
        let loaded = try XCTUnwrap(ThinkDiagScriptStore.current())
        XCTAssertEqual(loaded, imported)
        XCTAssertEqual(try loaded.plan().map(\.label), ["лицензия", "блок активации"])
    }

    /// The whole reason for importing rather than dropping a file in: a bad
    /// digit is caught here, with the step named, instead of at the car.
    func testAFileWithABadDigitIsRefusedWithTheStepNamed() throws {
        let broken = sampleJSON.replacingOccurrences(of: "01602802ccdd",
                                                     with: "01602802ccdz")
        let source = try write(broken, named: "broken.json")
        XCTAssertThrowsError(try ThinkDiagScriptStore.importFile(at: source)) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .badPayload("блок активации"))
        }
    }

    func testRubbishIsRefusedAsMalformed() throws {
        let source = try write("{ this is not json", named: "rubbish.json")
        XCTAssertThrowsError(try ThinkDiagScriptStore.importFile(at: source)) { error in
            guard case .malformed = error as? ThinkDiagScriptError else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testAScriptWithNoStepsIsRefused() throws {
        let empty = """
            {"application":"CITROEN V46.21","capturedAt":"2026-09-10","steps":[]}
            """
        let source = try write(empty, named: "empty.json")
        XCTAssertThrowsError(try ThinkDiagScriptStore.importFile(at: source)) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .empty)
        }
    }

    /// A failed import must leave the working script alone. Otherwise one
    /// mistaken tap in a car park costs the drive.
    func testAFailedImportDoesNotLoseTheScriptAlreadyLoaded() throws {
        let good = try write(sampleJSON, named: "good.json")
        let wanted = try ThinkDiagScriptStore.importFile(at: good)

        let broken = try write("{ nope", named: "broken.json")
        XCTAssertThrowsError(try ThinkDiagScriptStore.importFile(at: broken))

        XCTAssertEqual(ThinkDiagScriptStore.current(), wanted)
    }

    func testRemovingLeavesNothingBehind() throws {
        _ = try ThinkDiagScriptStore.importFile(at: try write(sampleJSON, named: "s.json"))
        XCTAssertNotNil(ThinkDiagScriptStore.current())

        ThinkDiagScriptStore.remove()
        XCTAssertNil(ThinkDiagScriptStore.current())
        XCTAssertThrowsError(try ThinkDiagScriptStore.loaded()) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .missing)
        }
    }

    func testWithNothingImportedThereIsNothingToFind() {
        XCTAssertNil(ThinkDiagScriptStore.current())
    }

    // MARK: - what the adapter does without one

    /// Without a script the six opening queries still run, and what they prove
    /// is worth keeping: the adapter answered, and this link carries `55aa`.
    /// So the failure comes last and says what is missing.
    func testWithoutAScriptTheAdapterStillIdentifiesItselfFirst() async throws {
        let fake = FakeSetupThinkDiag()
        let adapter = ThinkDiagAdapter(transport: fake, script: nil)
        do {
            try await adapter.open()
            XCTFail("it cannot open a session with no activation script")
        } catch {
            XCTAssertEqual(error as? ThinkDiagError, .noScript)
            XCTAssertTrue(error.localizedDescription.contains("настройках"),
                          error.localizedDescription)
        }

        let identity = await adapter.identity
        XCTAssertEqual(identity.model, "diagmini")
        let report = await adapter.report
        XCTAssertEqual(report.count, 7, report.joined(separator: " | "))
        XCTAssertTrue(report.last?.contains("diagmini") == true, report.last ?? "")
    }

    // MARK: -

    private let sampleJSON = """
        {
          "application": "CITROEN V46.21",
          "capturedAt": "2026-09-10",
          "steps": [
            {"label": "лицензия", "cmd": "21", "payload": "1802aabb"},
            {"label": "блок активации", "cmd": "27", "payload": "01602802ccdd",
             "expecting": "01ff00"}
          ]
        }
        """

    private func write(_ text: String, named name: String) throws -> URL {
        let url = root.appendingPathComponent("incoming-" + name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

/// Enough of a ThinkDiag to get through the six opening queries.
private final class FakeSetupThinkDiag: LinkTransport {
    private let lock = NSLock()
    private var pending: [Data] = []
    private var link = LinkStats()

    private let answers = [
        "03": "030003414200",
        "05": "05000a56312e32332e3030340000075632332e30350000075631302e3034"
            + "000009646961676d696e6900",
        "2a": "2a00",
        "11": "1100",
    ]

    func open() async throws {}
    func close() {}

    func write(_ data: Data) async throws {
        let reader = ThinkDiagFrameReader()
        reader.append(data)
        while let request = reader.next() {
            let key = request.payload.hexString
            let hex = request.cmd == 0x25 && key == "05" ? "0500" : answers[key]
            guard let payload = hex.flatMap({ Data(hex: $0) }) else { continue }
            let reply = ThinkDiagFrame(tag: .fromAdapter, seq: request.seq,
                                       cmd: request.cmd | ThinkDiagFrame.replyBit,
                                       payload: payload)
            lock.lock()
            pending.append(reply.encoded)
            lock.unlock()
        }
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
