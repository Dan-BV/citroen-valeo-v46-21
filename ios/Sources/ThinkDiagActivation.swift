import Foundation

/// Computing the activation response, so the adapter's live challenge is
/// answered rather than replayed.
///
/// The `016028` "DBS Car Security Certificate" exchange is a challenge-response:
/// the adapter returns a fresh nonce, and the app must reply with a value
/// derived from it. A replayed reply satisfies exactly the one nonce it was
/// captured against, which is why every on-car attempt was refused (`01ff02`).
///
/// Reversed from the downloaded CITROEN V10.34 vehicle software (`libSTD.so`
/// `Send_DBSCarSecurCertf` + `ExpandKey`/`Encrypt`) and validated byte-for-byte
/// against every captured pair — see `tools/thinkdiag/activation_ref.py` and
/// `out/thinkdiag_activation_apk.md`. The scheme:
///
///     nonce8 = the adapter's mode-1 reply with the 2-byte 0100 status stripped
///     key    = nonce8[2], nonce8[0], nonce8[6], nonce8[5], 0a 09 0c 08, then 8×00
///     text   = "CITROEN+1+V42.01$" zero-padded to 32 bytes
///     resp   = AES2_ECB(key, text) + b3 ab
///
/// The cipher is AES-128 reduced to two rounds with the standard S-box and Rcon;
/// this port was confirmed identical to the real `Encrypt` under emulation. The
/// constants are the vehicle software's "software cert": the indices `[2,0,6,5]`
/// and key bytes `0a090c08` are also echoed in the mode-1 request on the wire,
/// the strings are the cert's, and `b3ab` is its trailer. They are fixed for
/// this vehicle software, which is the only one this app targets.
enum ThinkDiagActivation {

    /// A `27` frame whose payload begins with one of these is the activation
    /// exchange: `01 60 28 <mode>`. Mode 1 asks for the nonce, mode 0 sends the
    /// response, mode 2 sends the licence block.
    static let mode1Prefix: [UInt8] = [0x01, 0x60, 0x28, 0x01]
    static let mode0Prefix: [UInt8] = [0x01, 0x60, 0x28, 0x00]

    private static let indices = [2, 0, 6, 5]
    private static let keyBytes: [UInt8] = [0x0a, 0x09, 0x0c, 0x08]
    private static let plaintext = Array("CITROEN+1+V42.01$".utf8)
    private static let trailer: [UInt8] = [0xb3, 0xab]

    /// The 8-byte nonce out of a mode-1 reply payload, or `nil` if it is too
    /// short or is a refusal. The two-byte `0100` status prefix is dropped.
    static func nonce(fromMode1Reply payload: Data) -> Data? {
        let bytes = Array(payload)
        guard bytes.count >= 10, bytes[0] == 0x01, bytes[1] == 0x00 else { return nil }
        return Data(bytes[2..<10])
    }

    /// The mode-0 frame payload — `01 60 28 00 <len> <response>` — computed for
    /// a given 8-byte nonce, to send in place of the script's stale bytes.
    static func mode0Payload(forNonce8 nonce8: Data) -> Data {
        let response = self.response(forNonce8: nonce8)
        var out = Data(mode0Prefix.dropLast())          // 01 60 28
        out.append(0x00)                                 // mode 0
        out.append(UInt8(response.count))                // len (34)
        out.append(response)
        return out
    }

    /// The response bytes for an 8-byte nonce: the two AES blocks plus trailer.
    static func response(forNonce8 nonce8: Data) -> Data {
        let n = Array(nonce8)
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 { key[i] = n[indices[i]] }
        for i in 0..<4 { key[4 + i] = keyBytes[i] }
        let rk = keyExpansion(key)

        var text = plaintext
        while text.count % 16 != 0 { text.append(0) }

        var cipher = [UInt8]()
        var i = 0
        while i < text.count {
            cipher += encryptBlock(Array(text[i..<i + 16]), rk)
            i += 16
        }
        return Data(cipher + trailer)
    }

    // MARK: - the cipher (AES-128, two rounds)

    private static let sbox: [UInt8] = {
        let hex = "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
            + "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
            + "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
            + "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
            + "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
            + "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
            + "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
            + "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
        return stride(from: 0, to: hex.count, by: 2).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[s...hex.index(after: s)], radix: 16)!
        }
    }()

    private static let rcon: [UInt8] = [0, 1, 2, 4, 8, 16, 32, 64, 128, 0x1b, 0x36]

    /// AES-128 key schedule truncated to three round keys (48 bytes).
    private static func keyExpansion(_ key16: [UInt8]) -> [UInt8] {
        var w = key16
        for i in 4..<12 {
            var t = Array(w[(i - 1) * 4..<(i - 1) * 4 + 4])
            if i % 4 == 0 {
                t = [sbox[Int(t[1])] ^ rcon[i / 4], sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
            }
            let prev = Array(w[(i - 4) * 4..<(i - 4) * 4 + 4])
            for j in 0..<4 { w.append(prev[j] ^ t[j]) }
        }
        return w
    }

    private static func xtime(_ a: UInt8) -> UInt8 {
        let s = UInt16(a) << 1
        return UInt8((s & 0x100) != 0 ? (s ^ 0x1b) & 0xff : s & 0xff)
    }

    private static func mixColumn(_ c: [UInt8]) -> [UInt8] {
        let t = c[0] ^ c[1] ^ c[2] ^ c[3]
        return [c[0] ^ t ^ xtime(c[0] ^ c[1]),
                c[1] ^ t ^ xtime(c[1] ^ c[2]),
                c[2] ^ t ^ xtime(c[2] ^ c[3]),
                c[3] ^ t ^ xtime(c[3] ^ c[0])]
    }

    /// SubBytes then ShiftRows, on a column-major state.
    private static func subShift(_ s: [UInt8]) -> [UInt8] {
        let b = s.map { sbox[Int($0)] }
        var out = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                out[c * 4 + r] = b[r + 4 * ((c + r) % 4)]
            }
        }
        return out
    }

    private static func encryptBlock(_ pt16: [UInt8], _ rk: [UInt8]) -> [UInt8] {
        var s = (0..<16).map { pt16[$0] ^ rk[$0] }        // AddRoundKey(0)
        // Round 1: SubBytes, ShiftRows, MixColumns, AddRoundKey(1)
        s = subShift(s)
        var mixed = [UInt8]()
        for c in 0..<4 { mixed += mixColumn(Array(s[c * 4..<c * 4 + 4])) }
        s = (0..<16).map { mixed[$0] ^ rk[16 + $0] }
        // Round 2 (final): SubBytes, ShiftRows, AddRoundKey(2)
        s = subShift(s)
        s = (0..<16).map { s[$0] ^ rk[32 + $0] }
        return s
    }
}
