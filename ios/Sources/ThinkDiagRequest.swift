import Foundation

/// Putting a diagnostic request onto `27/01`, and finding the ECU's answer in
/// what comes back.
///
/// This is where the ELM327 vocabulary stops and Launch's begins. Both halves
/// were derived from the capture and then checked against **all 438**
/// single-request exchanges in it - every `21xx8001` engine page, `81`,
/// `2180`, `17FF00`, and the BSI's `22xxxx` sweep - by
/// `tools/thinkdiag/verify_requests.py`. Not one disagreed.
enum ThinkDiagRequest {

    /// The link handle for the engine, V46.21.
    ///
    /// A handle is *not* a CAN identifier. No CAN identifier crosses this wire
    /// in any form: the identifiers live inside the vehicle software the
    /// adapter downloaded, and the phone only names a handle the adapter set
    /// up earlier. `6A8`/`688` therefore cannot be translated - they can only
    /// be looked up, and this is the one entry the capture proves.
    static let engineLink: UInt16 = 0x2905

    /// Fixed prologue of every single-request `27/01` payload. The `01` is the
    /// sub-command; the rest has no reading yet beyond being identical in all
    /// 438 of them.
    static let prologue: [UInt8] = [0x01, 0x64, 0x00, 0x01, 0xff, 0x02]

    /// The `27/01` payload carrying one request to one module:
    ///
    ///     01 64 00 01 ff 02 | L | 61 01 | n | link(2) | reqlen | request
    ///
    /// with `L = 6 + reqlen` and `n = 1 + reqlen`. Both counts are single
    /// bytes, which is what caps the request length - and `L` is the tighter
    /// of the two, so 249 is the limit. Nothing the session sends is longer
    /// than four bytes.
    ///
    /// The official app also has a form that packs several requests into one
    /// frame. We do not need it: the session asks one page at a time, and a
    /// second encoding would be a second thing to get wrong.
    static func payload(link: UInt16, request: Data) -> Data? {
        guard !request.isEmpty, request.count <= 249 else { return nil }
        let reqlen = UInt8(request.count)
        var out = Data(capacity: prologue.count + 7 + request.count)
        out.append(contentsOf: prologue)
        out.append(6 + reqlen)
        out.append(0x61)
        out.append(0x01)
        out.append(1 + reqlen)
        out.append(UInt8(link >> 8))
        out.append(UInt8(link & 0xff))
        out.append(reqlen)
        out.append(request)
        return out
    }

    /// Whether a `67/01` payload is a bare status rather than ECU data.
    ///
    /// 26 of the 438 answers are these, `01ff00` and `01ff02`, and they are
    /// what the ECU-did-not-answer case looks like on this adapter - the
    /// equivalent of an ELM327 printing `NO DATA`.
    static func isStatus(_ payload: Data) -> Bool {
        payload.count >= 2
            && payload[payload.startIndex] == 0x01
            && payload[payload.index(after: payload.startIndex)] == 0xff
    }

    /// The ECU's answer inside a `67/01` payload, or `nil` when there is none
    /// to find.
    ///
    /// The answer is nested, in a frame of the same `55aa` shape as the outer
    /// one but with its own header:
    ///
    ///     01 00 nn nn | 55aa | ? ? | module(2) | length | answer
    ///
    /// The two bytes after the preamble and the module tag have no reading
    /// yet, and they do not need one - the length settles where the answer
    /// starts. It comes in two widths: one byte for a short answer, or two
    /// bytes with **bit 12 set** for a long one, the low twelve bits being the
    /// count. So `03` means three bytes follow, and `1437` means 1079 do.
    ///
    /// **The wide form has to be tried first.** Checking one byte first looks
    /// safer and is not: on one of the 438 answers a byte in that position
    /// happened to equal the count of everything after it, and the narrow
    /// reading swallowed the first real byte of a `62 21 02 …` reply. Bit 12
    /// of a two-byte field is a far stronger signal than a coincidence of
    /// arithmetic, so it goes first, and then 438 of 438 agree.
    static func answer(in payload: Data) -> Data? {
        guard let at = firstPreamble(in: payload) else { return nil }
        let rest = payload[payload.index(at, offsetBy: 6)...]
        if rest.count >= 2 {
            let wide = Int(rest[rest.startIndex]) << 8 | Int(rest[rest.index(after: rest.startIndex)])
            if wide & 0x1000 != 0, rest.count - 2 == wide & 0x0fff {
                return Data(rest.dropFirst(2))
            }
        }
        if let length = rest.first, rest.count - 1 == Int(length) {
            return Data(rest.dropFirst())
        }
        return nil
    }

    /// The nested preamble, if the payload is long enough to hold a header
    /// after it.
    private static func firstPreamble(in payload: Data) -> Data.Index? {
        guard payload.count >= 7 else { return nil }
        var i = payload.startIndex
        let last = payload.index(payload.endIndex, offsetBy: -7)
        while i <= last {
            if payload[i] == 0x55, payload[payload.index(after: i)] == 0xaa { return i }
            i = payload.index(after: i)
        }
        return nil
    }
}
