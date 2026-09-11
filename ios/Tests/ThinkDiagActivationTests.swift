import XCTest

/// The activation response, against the values the official app put on the wire.
///
/// These two pairs are real, out of the 2026-09-10 CITROEN captures: the
/// adapter's mode-1 reply (the nonce) and the mode-0 response the app computed
/// from it. The whole point of the reverse-engineering was to reproduce that
/// computation, so the pairs are the proof, exactly as
/// `tools/thinkdiag/activation_ref.py` checks them in Python.
final class ThinkDiagActivationTests: XCTestCase {

    /// The captured (mode-1 reply, mode-0 response) pairs.
    private let pairs = [
        ("0100890bef0a034c2508",
         "c85bb75126d4ca6182128967ae28737d79b7c99c3d458bb3774568be2818cdb1b3ab"),
        ("0100000b770a0346f408",
         "215cc94d9ca8d9abd59a1272bdea00501b6fab83e922e15d18a2e2e1f2cb7dd0b3ab"),
    ]

    func testTheResponseMatchesEveryCapturedPair() {
        for (reply, response) in pairs {
            let nonce = try! XCTUnwrap(ThinkDiagActivation.nonce(fromMode1Reply: hex(reply)))
            XCTAssertEqual(ThinkDiagActivation.response(forNonce8: nonce).hexString, response,
                           "nonce \(nonce.hexString)")
        }
    }

    /// A fresh nonce gives a different response - it must, or it would be the
    /// replay that the adapter refuses.
    func testADifferentNonceGivesADifferentResponse() {
        let a = ThinkDiagActivation.response(forNonce8: hex("890bef0a034c2508"))
        let b = ThinkDiagActivation.response(forNonce8: hex("000b770a0346f408"))
        XCTAssertNotEqual(a, b)
        // But the trailer is constant.
        XCTAssertEqual(a.suffix(2), hex("b3ab"))
        XCTAssertEqual(b.suffix(2), hex("b3ab"))
    }

    /// The 8-byte nonce is the reply with the two-byte `0100` status dropped.
    func testTheNonceIsTheReplyWithoutTheStatus() {
        XCTAssertEqual(ThinkDiagActivation.nonce(fromMode1Reply: hex("0100890bef0a034c2508")),
                       hex("890bef0a034c2508"))
        // A refusal (01ff…) or a short reply is not a nonce.
        XCTAssertNil(ThinkDiagActivation.nonce(fromMode1Reply: hex("01ff02")))
        XCTAssertNil(ThinkDiagActivation.nonce(fromMode1Reply: hex("010089")))
    }

    /// The mode-0 frame payload is `01 60 28 00 <len> <response>`, the shape the
    /// captured step-11 request had.
    func testTheMode0PayloadIsFramedLikeTheCapture() {
        let nonce = hex("890bef0a034c2508")
        let payload = ThinkDiagActivation.mode0Payload(forNonce8: nonce)
        XCTAssertEqual(payload.hexString,
                       "01602800" + "22"
                       + "c85bb75126d4ca6182128967ae28737d79b7c99c3d458bb3774568be2818cdb1b3ab")
        XCTAssertEqual(payload.prefix(4).hexString, "01602800")
        XCTAssertEqual(payload[4], 0x22, "length of the 34-byte response")
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
