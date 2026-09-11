import XCTest

/// The fast-channel patch, against the one frame it is allowed to touch.
///
/// The channel-open frame is real, out of the CITROEN capture and carried
/// verbatim in the activation script: `01 60 18 0c | 55 aa 08 61 01 03 2905 30
/// 00 0a 7d`. The `0a` is the ISO-TP separation time (10 ms) the whole
/// experiment exists to lower; `7d` is the nested frame's checksum.
final class ThinkDiagFastChannelTests: XCTestCase {

    private let openFrame = "0160180c55aa08610103290530000a7d"

    /// STmin goes to 0 and the checksum follows: `7d ^ 0a ^ 00 = 77`.
    func testTheOpenFrameGetsStMinZeroAndAFixedChecksum() {
        let patched = try! XCTUnwrap(ThinkDiagFastChannel.patched(hex(openFrame)))
        XCTAssertEqual(patched.hexString, "0160180c55aa08610103290530000077")
    }

    /// A custom separation time is honoured, checksum too: `7d ^ 0a ^ f1 = 86`.
    func testACustomStMinIsWrittenWithItsChecksum() {
        let patched = try! XCTUnwrap(ThinkDiagFastChannel.patched(hex(openFrame), stMin: 0xf1))
        XCTAssertEqual(patched.hexString, "0160180c55aa0861010329053000f186")
    }

    /// The nested checksum of the patched frame is genuinely valid by the XOR
    /// rule the reader enforces - an independent recompute, not a repeat of the
    /// patch's own arithmetic.
    func testThePatchedFrameHasAValidNestedChecksum() {
        let bytes = Array(try! XCTUnwrap(ThinkDiagFastChannel.patched(hex(openFrame))))
        // The nested frame starts at the 55aa, four bytes into the payload; its
        // checksum is the last byte, an XOR of everything from the length byte.
        let nest = 4
        var xor: UInt8 = 0
        for b in bytes[(nest + 2)..<(bytes.count - 1)] { xor ^= b }
        XCTAssertEqual(xor, bytes.last)
    }

    /// A frame already at the wanted separation time is left alone, so the
    /// caller can tell a real rewrite from a no-op.
    func testAnAlreadyFastFrameIsNotPatchedAgain() {
        let fast = "0160180c55aa08610103290530000077"
        XCTAssertNil(ThinkDiagFastChannel.patched(hex(fast)))
    }

    /// Nothing but the channel-open frame matches. An activation step and an
    /// engine request both pass through untouched.
    func testOtherPayloadsAreNotTouched() {
        XCTAssertNil(ThinkDiagFastChannel.patched(hex("016028013002")))
        XCTAssertNil(ThinkDiagFastChannel.patched(hex("01640001ff020d610108290504" + "21c08001")))
        XCTAssertNil(ThinkDiagFastChannel.patched(Data()))
    }

    private func hex(_ s: String) -> Data { Data(hex: s)! }
}
