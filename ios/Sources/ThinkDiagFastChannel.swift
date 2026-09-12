import Foundation

/// The "fast channel": lowering the ISO-TP separation time the
/// adapter imposes while it reads a module's answer.
///
/// The engine channel is opened with a flow-control frame nested in a `27`
/// payload:
///
///     01 60 18 0c | 55 aa 08 61 01 03 <link> 30 00 0a <cksum>
///                                             └FC┘└BS┘└ST┘
///
/// `30` is the ISO-TP flow-control "continue to send", `00` the block size
/// (unlimited), and `0a` the **separation time, 10 ms** — the minimum gap the
/// ECU must leave between the consecutive frames of its multi-frame answer. A
/// 183-byte page is ~26 such frames, so 10 ms each is ~260 ms of pure trickle,
/// off the BLE wire, inside the adapter. That is measurably the whole cost of a
/// page: the per-page time on the 2026-09-10 drive fits `27 + 1.39·bytes` ms,
/// and `1.39 ms/byte` is exactly `10 ms / 7 bytes`.
///
/// The ELM327 path proves the ECU can stream far faster than this — the same
/// 183 bytes come back in 144 ms there, bounded by BLE notifications, not by
/// separation time — so the `0a` is the adapter's own conservative choice, not
/// a limit of the car. Rewriting it to `00` asks the ECU to send its
/// consecutive frames back-to-back.
///
/// Proven on the car on 2026-09-12: the adapter passes the value through, the
/// multi-frame pages halve (C0 248 -> 116 ms) and the cycle drops 930 -> 555 ms,
/// which puts the ThinkDiag ahead of the ELM327 for the first time. So this is
/// always on. The change is a single byte and touches only the pace of the
/// answer, never what is asked. See out/drives/2026-09-12_thinkdiag_fast_channel.md.
enum ThinkDiagFastChannel {

    /// The separation time to ask for: `00` = 0 ms,
    /// the fastest the millisecond encoding expresses.
    static let fastStMin: UInt8 = 0x00

    /// The six bytes that open a module's link: `55 aa 08 61 01 03`, the nested
    /// frame's preamble, length and `6101 03` command. The flow-control triplet
    /// `30 <bs> <stmin>` and the checksum follow the two-byte link after it.
    private static let openMarker: [UInt8] = [0x55, 0xaa, 0x08, 0x61, 0x01, 0x03]

    /// A channel-open payload with its separation time rewritten, or `nil` when
    /// the payload is not a channel-open or already carries the wanted value —
    /// so the caller can tell "patched" from "left alone".
    ///
    /// Only the separation-time byte and the nested checksum change. The
    /// checksum is an XOR over the run that includes the separation time and
    /// excludes itself, so flipping one byte flips the checksum by the same
    /// XOR — no need to know the other bytes.
    static func patched(_ payload: Data, stMin: UInt8 = fastStMin) -> Data? {
        var bytes = Array(payload)
        guard let m = firstIndex(of: openMarker, in: bytes) else { return nil }
        let fc = m + openMarker.count + 2      // skip the marker and the 2-byte link
        let st = fc + 2
        let ck = fc + 3
        guard ck < bytes.count, bytes[fc] == 0x30 else { return nil }
        let old = bytes[st]
        guard old != stMin else { return nil }
        bytes[st] = stMin
        bytes[ck] = bytes[ck] ^ old ^ stMin
        return Data(bytes)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}
