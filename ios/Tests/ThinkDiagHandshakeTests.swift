import XCTest

/// The opening exchange: the strings the adapter answers with, the step list,
/// and the licence script that has to be loaded from outside the repository.
///
/// The two identity replies here are real, out of the 2026-09-10 capture. The
/// rest is the plumbing around them, where the failures that matter are quiet
/// ones: a NUL left on the end of a version string, a truncated reply decoding
/// as a short list, a script file with one bad digit sending 1627 bytes of
/// something else.
final class ThinkDiagHandshakeTests: XCTestCase {

    // MARK: - hex

    func testHexRoundTripsAndIgnoresWhitespace() {
        XCTAssertEqual(Data(hex: "55aaf0f8")?.hexString, "55aaf0f8")
        XCTAssertEqual(Data(hex: "55 aa\nf0 f8"), Data(hex: "55aaf0f8"))
        XCTAssertEqual(Data(hex: "55AAF0F8"), Data(hex: "55aaf0f8"))
        XCTAssertEqual(Data(hex: ""), Data())
    }

    /// A script file wrong by one character must not become bytes that get
    /// sent. Both ways it can be wrong.
    func testHexRefusesOddDigitsAndNonHex() {
        XCTAssertNil(Data(hex: "5"))
        XCTAssertNil(Data(hex: "55aaf"))
        XCTAssertNil(Data(hex: "55zz"))
        XCTAssertNil(Data(hex: "0x55"))
    }

    // MARK: - the strings the adapter answers with

    /// `61/03`, as captured. The NUL inside each length is the thing to get
    /// right: keep it and every one of these values is one character longer
    /// than it looks, which only shows up when one is compared.
    func testTheIdentityReplyDecodesToFiveStrings() {
        var identity = ThinkDiagIdentity()
        XCTAssertTrue(identity.readIdentity(Data(hex: identityPayload)!))
        XCTAssertEqual(identity.identity,
                       ["2e2d5335373636134e383632", "979865497037",
                        "V1.00.000", "20260130", "13"])
        XCTAssertEqual(identity.firmware, "V1.00.000")
        XCTAssertEqual(identity.built, "20260130")
        XCTAssertEqual(identity.serial, "979865497037")
        XCTAssertFalse(identity.firmware.contains("\u{0}"), "the NUL must be gone")
    }

    /// `61/05`, as captured.
    func testTheVersionReplyDecodesToFourStrings() {
        var identity = ThinkDiagIdentity()
        XCTAssertTrue(identity.readVersions(Data(hex: versionPayload)!))
        XCTAssertEqual(identity.versions, ["V1.23.004", "V23.05", "V10.04", "diagmini"])
        XCTAssertEqual(identity.model, "diagmini")
        XCTAssertTrue(identity.isDiagMini)
    }

    func testBothRepliesTogetherMakeALogLine() {
        var identity = ThinkDiagIdentity()
        _ = identity.readIdentity(Data(hex: identityPayload)!)
        _ = identity.readVersions(Data(hex: versionPayload)!)
        XCTAssertEqual(identity.summary, "diagmini · V1.23.004 · V1.00.000 · 979865497037")
    }

    func testAnAdapterWithNothingReadYetSaysSo() {
        XCTAssertEqual(ThinkDiagIdentity().summary, "неизвестный адаптер")
        XCTAssertFalse(ThinkDiagIdentity().isDiagMini)
    }

    /// A length that runs past the end must not decode as a shorter list: that
    /// is indistinguishable from an adapter that answered with fewer fields,
    /// and one of those is a truncated read to retry while the other is not.
    func testATruncatedReplyDoesNotDecode() {
        XCTAssertNil(ThinkDiagStrings.decode(Data(hex: "000a56312e30302e30")!))
        XCTAssertNil(ThinkDiagStrings.decode(Data(hex: "0003414243000200")!))
    }

    /// One byte left over is not a length.
    func testAnOddTailDoesNotDecode() {
        XCTAssertNil(ThinkDiagStrings.decode(Data(hex: "000341424300")!))
    }

    func testAZeroLengthStringIsEmptyNotAFailure() {
        XCTAssertEqual(ThinkDiagStrings.decode(Data(hex: "00000003414200")!), ["", "AB"])
    }

    /// The reply to a different query must not be read as this one's.
    func testAReplyForAnotherQueryIsRefused() {
        var identity = ThinkDiagIdentity()
        XCTAssertFalse(identity.readVersions(Data(hex: identityPayload)!))
        XCTAssertTrue(identity.versions.isEmpty, "and nothing is left half-written")
        XCTAssertFalse(identity.readIdentity(Data(hex: versionPayload)!))
        XCTAssertTrue(identity.identity.isEmpty)
    }

    /// A short reply reads as blank fields, never as the later values shifted
    /// into the earlier names.
    func testAShortReplyLeavesTheLaterFieldsBlank() {
        var identity = ThinkDiagIdentity()
        XCTAssertTrue(identity.readIdentity(Data(hex: "030003414200")!))
        XCTAssertEqual(identity.hardwareId, "AB")
        XCTAssertEqual(identity.serial, "")
        XCTAssertEqual(identity.firmware, "")
        XCTAssertEqual(identity.model, "")
    }

    // MARK: - the opening

    /// Six queries, in the captured order, including the duplicate `21/03`.
    func testTheOpeningIsTheSixCapturedQueries() {
        let opening = ThinkDiagHandshake.opening
        XCTAssertEqual(opening.map(\.cmd), [0x21, 0x21, 0x21, 0x21, 0x25, 0x21])
        XCTAssertEqual(opening.compactMap { $0.payload.first },
                       [0x03, 0x03, 0x05, 0x2a, 0x05, 0x11])
        XCTAssertEqual(opening[ThinkDiagHandshake.identityStep].payload.first, 0x03)
        XCTAssertEqual(opening[ThinkDiagHandshake.versionStep].payload.first, 0x05)
        XCTAssertTrue(opening.allSatisfy { !$0.label.isEmpty }, "every step has to be nameable")
    }

    func testAStepBecomesARequestFrame() {
        let step = ThinkDiagStep(label: "версии", cmd: 0x21, payload: Data([0x05]))
        let frame = step.frame(seq: 0x2d)
        XCTAssertEqual(frame.tag, .toAdapter)
        XCTAssertEqual(frame.encoded, Data(hex: "55aaf0f800032d210502"))
    }

    // MARK: - judging a reply

    func testAProperAnswerIsAccepted() {
        let step = ThinkDiagStep(label: "версии", cmd: 0x21, payload: Data([0x05]))
        let request = step.frame(seq: 0x2d)
        let reply = ThinkDiagFrame(tag: .fromAdapter, seq: 0x2d, cmd: 0x61,
                                   payload: Data(hex: versionPayload)!)
        XCTAssertEqual(ThinkDiagHandshake.judge(step, request: request, reply: reply),
                       .answered(Data(hex: versionPayload)!))
    }

    func testNoAnswerEndsTheHandshake() {
        let step = ThinkDiagHandshake.opening[0]
        let request = step.frame(seq: 1)
        let result = ThinkDiagHandshake.judge(step, request: request, reply: nil)
        XCTAssertEqual(result, .silent)
        XCTAssertTrue(result.isFailure)
        XCTAssertNil(result.payload)
    }

    /// A frame that does not answer this request is worth no more than
    /// nothing: it is a late reply to the step before, or something we do not
    /// understand, and reading it as this step's answer is how a handshake
    /// goes wrong quietly.
    func testAFrameThatAnswersSomethingElseIsNotAnAnswer() {
        let step = ThinkDiagHandshake.opening[0]
        let request = step.frame(seq: 7)
        let wrongId = ThinkDiagFrame(tag: .fromAdapter, seq: 8, cmd: 0x61, payload: Data([0x03]))
        let wrongCmd = ThinkDiagFrame(tag: .fromAdapter, seq: 7, cmd: 0x67, payload: Data([0x03]))
        XCTAssertEqual(ThinkDiagHandshake.judge(step, request: request, reply: wrongId), .silent)
        XCTAssertEqual(ThinkDiagHandshake.judge(step, request: request, reply: wrongCmd), .silent)
    }

    /// An expectation exists to be reported, not to fail a session on. Three
    /// sessions with one adapter is not enough to call an unexpected answer
    /// broken.
    func testAnUnexpectedAnswerIsReportedButNotFatal() {
        let step = ThinkDiagStep(label: "запрос 11", cmd: 0x21, payload: Data([0x11]),
                                 expecting: Data([0x11, 0x00]))
        let request = step.frame(seq: 3)
        let odd = Data([0x11, 0x06])
        let result = ThinkDiagHandshake.judge(
            step, request: request,
            reply: ThinkDiagFrame(tag: .fromAdapter, seq: 3, cmd: 0x61, payload: odd))
        XCTAssertEqual(result, .unexpected(odd))
        XCTAssertFalse(result.isFailure)
        XCTAssertEqual(result.payload, odd)

        let expected = Data([0x11, 0x00])
        XCTAssertEqual(
            ThinkDiagHandshake.judge(
                step, request: request,
                reply: ThinkDiagFrame(tag: .fromAdapter, seq: 3, cmd: 0x61, payload: expected)),
            .answered(expected))
    }

    // MARK: - the licence script

    func testWithoutAScriptThePlanIsTheOpeningAlone() throws {
        XCTAssertEqual(try ThinkDiagHandshake.plan(with: nil).map(\.label),
                       ThinkDiagHandshake.opening.map(\.label))
    }

    func testAScriptIsAppendedToTheOpeningInOrder() throws {
        let plan = try ThinkDiagHandshake.plan(with: sampleScript)
        XCTAssertEqual(plan.count, ThinkDiagHandshake.opening.count + 2)
        XCTAssertEqual(plan.suffix(2).map(\.label), ["лицензия", "блок активации"])
        XCTAssertEqual(plan[plan.count - 2].cmd, 0x21)
        XCTAssertEqual(plan[plan.count - 2].payload, Data(hex: "1802aabb"))
        XCTAssertEqual(plan.last?.expecting, Data(hex: "01ff00"))
    }

    func testABadDigitInAPayloadIsRefusedWithTheStepNamed() {
        var script = sampleScript
        script.steps[0].payload = "1802aab"
        XCTAssertThrowsError(try script.plan()) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .badPayload("лицензия"))
        }
    }

    func testACommandThatIsNotOneByteIsRefused() {
        var script = sampleScript
        script.steps[0].cmd = "2101"
        XCTAssertThrowsError(try script.plan()) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .badCommand("лицензия"))
        }
    }

    /// A step with no payload has no sub-command, so it is not a step.
    func testAnEmptyPayloadIsRefused() {
        var script = sampleScript
        script.steps[0].payload = ""
        XCTAssertThrowsError(try script.plan()) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .badPayload("лицензия"))
        }
    }

    // MARK: - loading it off the disk

    func testAMissingScriptSaysWhichFileIsMissing() throws {
        let directory = try emptyDirectory()
        XCTAssertThrowsError(try ThinkDiagScript.load(in: directory)) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .missing)
            XCTAssertEqual(
                (error as? ThinkDiagScriptError)?.errorDescription,
                "Нет файла thinkdiag_script.json в папке приложения")
        }
    }

    func testAScriptSurvivesBeingWrittenAndReadBack() throws {
        let directory = try emptyDirectory()
        try write(sampleScript, to: directory)
        let loaded = try ThinkDiagScript.load(in: directory)
        XCTAssertEqual(loaded, sampleScript)
        XCTAssertEqual(try loaded.plan().map(\.label), ["лицензия", "блок активации"])
    }

    func testRubbishInTheFileIsReportedAsMalformed() throws {
        let directory = try emptyDirectory()
        try Data("not json at all".utf8).write(to: ThinkDiagScript.url(in: directory))
        XCTAssertThrowsError(try ThinkDiagScript.load(in: directory)) { error in
            guard case .malformed = error as? ThinkDiagScriptError else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testAScriptWithNoStepsIsRefused() throws {
        let directory = try emptyDirectory()
        var empty = sampleScript
        empty.steps = []
        try write(empty, to: directory)
        XCTAssertThrowsError(try ThinkDiagScript.load(in: directory)) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .empty)
        }
    }

    /// Loading is where a bad digit has to be caught. Finding it mid-handshake
    /// leaves the adapter holding a half-opened session, and the licence step
    /// is 525 bytes - nobody is going to spot it by eye.
    func testABadDigitIsCaughtWhenTheFileIsLoadedNotWhenItIsSent() throws {
        let directory = try emptyDirectory()
        var broken = sampleScript
        broken.steps[1].payload = "01602802zz"
        try write(broken, to: directory)
        XCTAssertThrowsError(try ThinkDiagScript.load(in: directory)) { error in
            XCTAssertEqual(error as? ThinkDiagScriptError, .badPayload("блок активации"))
        }
    }

    // MARK: - fixtures

    /// `61/03` and `61/05` payloads, sub-command byte included, copied out of
    /// the 2026-09-10 CITROEN capture.
    private let identityPayload = """
        03001932653264353333353337333633363133346533383336333200000d3937393836\
        3534393730333700000a56312e30302e3030300000093230323630313330000003313300
        """

    private let versionPayload = """
        05000a56312e32332e3030340000075632332e3035000007\
        5631302e3034000009646961676d696e6900
        """

    /// Shaped like the real thing, with the blobs cut down to four bytes: the
    /// real script is 2564 bytes of the adapter's credentials and does not
    /// belong in a repository.
    private var sampleScript: ThinkDiagScript {
        ThinkDiagScript(
            application: "CITROEN V46.21",
            capturedAt: "2026-09-10",
            note: "fixture",
            steps: [
                .init(label: "лицензия", cmd: "21", payload: "1802aabb", expecting: "180200aabb08"),
                .init(label: "блок активации", cmd: "27", payload: "01602802ccdd",
                      expecting: "01ff00"),
            ])
    }

    private func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thinkdiag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ script: ThinkDiagScript, to directory: URL) throws {
        try JSONEncoder().encode(script).write(to: ThinkDiagScript.url(in: directory))
    }
}
