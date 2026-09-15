import XCTest

/// The frame that opens a module's channel, and the handle table the sweep
/// walks.
///
/// The frame is built rather than replayed now - the replay script carries only
/// the engine's - so the rule that builds it has to reproduce the captured one
/// exactly, checksum included. It does: all 68 channel opens in the captures
/// come out byte for byte, and the engine's is pinned here.
final class ThinkDiagLinkTests: XCTestCase {

    /// Step 12 of the replay script, as the official app sent it: separation
    /// time `0a`, checksum `7d`.
    private let engineOpen = "0160180c55aa08610103290530000a7d"

    func testTheEnginesChannelOpenIsReproducedByteForByte() {
        let built = ThinkDiagLink.openChannel(0x2905, stMin: 0x0a)
        XCTAssertEqual(built.hexString, engineOpen)
    }

    /// The fast channel is the default: ask the ECU for no gap between the
    /// consecutive frames of its answer. Only that byte and the checksum move.
    func testTheFastChannelIsTheDefaultAndOnlyMovesTwoBytes() {
        let fast = ThinkDiagLink.openChannel(0x2905).hexString
        let slow = engineOpen
        XCTAssertEqual(fast.count, slow.count)
        XCTAssertEqual(fast.prefix(slow.count - 4), slow.prefix(slow.count - 4))
        XCTAssertTrue(fast.hasSuffix("0077"), fast)
        // Which is what the fast-channel patch makes of the captured frame.
        let patched = ThinkDiagFastChannel.patched(Data(hex: slow)!)
        XCTAssertEqual(patched?.hexString, fast)
    }

    /// The checksum is an XOR over the nested frame, so a handle that differs
    /// in one byte gives a checksum that differs by the same XOR.
    func testTheChecksumFollowsTheHandle() {
        for link: UInt16 in [0x2a25, 0x1f7f, 0x10ce, 0x4fca] {
            let bytes = Array(ThinkDiagLink.openChannel(link))
            let nested = bytes[4 + 2..<bytes.count - 1]   // after 55aa, before the checksum
            XCTAssertEqual(bytes.last, nested.reduce(0, ^), String(format: "%04x", link))
        }
    }

    func testAHandleIsWrittenWhereACanHeaderWouldGo() {
        XCTAssertEqual(ThinkDiagLink.header(for: 0x2905), "#2905")
        XCTAssertEqual(ThinkDiagLink.link(inHeader: "#2905"), 0x2905)
        XCTAssertEqual(ThinkDiagLink.link(inHeader: "#10CE"), 0x10ce)
        // A CAN identifier is not a handle, and must not be read as one.
        XCTAssertNil(ThinkDiagLink.link(inHeader: "6A8"))
        XCTAssertNil(ThinkDiagLink.link(inHeader: "752"))
    }

    /// Thirty-four handles, the engine's among them, none repeated.
    func testTheHandleTableIsTheCapturedSystemScan() {
        XCTAssertEqual(ThinkDiagLink.known.count, 34)
        XCTAssertEqual(Set(ThinkDiagLink.known).count, ThinkDiagLink.known.count)
        XCTAssertTrue(ThinkDiagLink.known.contains(0x2905), "the engine")
        XCTAssertTrue(ThinkDiagLink.known.contains(0x2a25), "the BSI")
    }

    // MARK: - what a handle probe can name

    /// A handle probe has no address, so it can only name the class of module
    /// that answers a given recognition frame. The classes have to cover the
    /// whole map, or a live module would be walked past.
    func testRecognitionClassesCoverEveryModuleOfThePlatform() throws {
        let scan = try ScanProfile.bundled(in: Bundle(for: ThinkDiagLinkTests.self))
        let classes = scan.recognitionClasses
        XCTAssertEqual(classes.reduce(0) { $0 + $1.members.count }, scan.targets.count)
        // Most populous first, so a probe tries the likeliest frames first.
        XCTAssertEqual(classes.map { $0.members.count },
                       classes.map { $0.members.count }.sorted(by: >))
        // Every member of a class really does answer that class's frames.
        for group in classes {
            for member in group.members {
                XCTAssertEqual(member.reco, group.reco, member.name)
                XCTAssertEqual(member.openSession, group.openSession, member.name)
            }
            // And the layouts to try are the distinct ones its members use.
            let used = Set(group.members.compactMap { $0.faults })
            XCTAssertEqual(Set(group.faultLayouts), used, group.reco)
        }
    }
}
