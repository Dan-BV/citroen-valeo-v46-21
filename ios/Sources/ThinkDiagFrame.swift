import Foundation

/// Which way a frame is going. Any other value is not a frame at all, which is
/// what makes this a resynchronisation check and not decoration - see
/// `ThinkDiagFrameReader`.
enum ThinkDiagTag: UInt16 {
    case toAdapter = 0xf0f8
    case fromAdapter = 0xf8f0
}

/// One frame of Launch's `55aa` protocol - what a ThinkDiag speaks instead of
/// the ELM327 text vocabulary.
///
///     55aa | tag(2) | len(2) | seq(1) | cmd(1) | payload | cksum(1)
///
/// `len` is big-endian and counts `seq` through the end of the payload, so a
/// whole frame is `7 + len` bytes. `cksum` is the XOR of every byte from `tag`
/// through the payload, with the `55aa` preamble and the checksum byte itself
/// excluded. A reply echoes the request's `seq` and answers with `cmd | 0x40`.
///
/// This was recovered from the official app's own frame logs rather than from
/// documentation, so `tools/thinkdiag/verify_frames.py` re-checks every rule
/// above against all 12 040 captured frames. It found no violation, and no
/// reply that failed to echo its request. The captures stay out of the
/// repository - they carry the adapter's licence blob - which is why the tests
/// alongside this file hold a few real frames inline instead of reading one.
///
/// The payload is deliberately opaque here. What `cmd` and its first payload
/// byte mean is the handshake's business (`21/03`, `21/05`, the licence) and
/// the request path's (`27/01`); this type only gets frames on and off the
/// wire intact.
struct ThinkDiagFrame: Equatable {

    /// Marks the start of a frame - and, one payload in three, something in the
    /// middle of one. See `ThinkDiagFrameReader`.
    static let preamble: [UInt8] = [0x55, 0xaa]

    /// What a reply sets on the request's `cmd`: `21` is answered by `61`,
    /// `25` by `65`, `27` by `67`.
    static let replyBit: UInt8 = 0x40

    /// Bytes before `seq`: the preamble, the tag and the length.
    static let headerLength = 6

    /// The smallest `len` a frame can declare - `seq` and `cmd`, no payload.
    static let minBodyLength = 2

    /// A declared length past this is taken as corruption rather than waited
    /// for, so a bad length field cannot stall the reader forever. The widest
    /// frame in the captures is 1636 bytes, the 1629-byte licence going out.
    static let maxFrameLength = 4096

    var tag: ThinkDiagTag

    /// The transaction id. Not a position in a stream despite the name the
    /// protocol gives it: the official app opens with arbitrary values and only
    /// then settles into counting. All that is required is that a reply carries
    /// the same one back.
    var seq: UInt8

    var cmd: UInt8
    var payload: Data

    init(tag: ThinkDiagTag, seq: UInt8, cmd: UInt8, payload: Data = Data()) {
        self.tag = tag
        self.seq = seq
        self.cmd = cmd
        self.payload = payload
    }

    /// A frame headed for the adapter.
    static func request(seq: UInt8, cmd: UInt8, payload: Data = Data()) -> ThinkDiagFrame {
        ThinkDiagFrame(tag: .toAdapter, seq: seq, cmd: cmd, payload: payload)
    }

    /// The sub-command: every `cmd` seen is subdivided by the payload's first
    /// byte, which is what makes the capture's `21/03` and `27/01` notation
    /// mean anything. `nil` for an empty payload.
    var sub: UInt8? { payload.first }

    /// The frame on the wire, checksum included.
    var encoded: Data {
        var out = Data(capacity: ThinkDiagFrame.headerLength + 2 + payload.count + 1)
        out.append(contentsOf: ThinkDiagFrame.preamble)
        let body = UInt16(ThinkDiagFrame.minBodyLength + payload.count)
        out.append(UInt8(tag.rawValue >> 8))
        out.append(UInt8(tag.rawValue & 0xff))
        out.append(UInt8(body >> 8))
        out.append(UInt8(body & 0xff))
        out.append(seq)
        out.append(cmd)
        out.append(payload)
        // Everything but the preamble, which is why the drop is two and not
        // zero: the preamble is a marker, not part of the protected body.
        out.append(ThinkDiagFrame.checksum(out.dropFirst(ThinkDiagFrame.preamble.count)))
        return out
    }

    /// Whether this is the adapter's answer to `request`. Both halves matter:
    /// the id alone repeats every 256 exchanges, and the command alone cannot
    /// tell one page's answer from the next one's.
    func answers(_ request: ThinkDiagFrame) -> Bool {
        tag == .fromAdapter
            && seq == request.seq
            && cmd == request.cmd | ThinkDiagFrame.replyBit
    }

    /// XOR of the bytes handed in. Not a checksum that catches much, but it is
    /// the one the adapter computes.
    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }
}

/// The transaction ids a session hands out, one per exchange.
///
/// Wraps through zero, because 2708 exchanges in one captured session ran the
/// counter round ten times and the adapter never minded. Starts at 1 to match
/// where the official app's data phase begins.
struct ThinkDiagSequence {
    private var value: UInt8

    init(startingAt start: UInt8 = 1) {
        value = start
    }

    mutating func next() -> UInt8 {
        let issued = value
        value = value &+ 1
        return issued
    }
}

/// Frames out of a byte stream that has no framing of its own.
///
/// BLE delivers notification-sized pieces, and the pieces have nothing to do
/// with frame boundaries: 672 of the 12 040 captured frames are longer than the
/// 93 bytes this adapter's notifications carry, the widest by a factor of
/// seventeen. So a frame is accumulated against its declared length.
///
/// **It has to be the declared length and not the next preamble.** A third of
/// the captured payloads - 7778 occurrences across 12 040 frames - contain the
/// bytes `55aa` themselves, because a `27/01` reply carries the ECU's answer as
/// a nested frame of the same shape. A reader that scanned for the preamble
/// would cut those frames in half.
///
/// Resynchronisation is still needed for the other direction - a stream that
/// starts mid-frame, or loses bytes - so a candidate is rejected unless its tag
/// is one of the two real ones and its checksum agrees. Neither test is
/// theoretical: of those 7778 nested preambles, not one is followed by a valid
/// tag, so the cheaper test already rejects every false start in the capture
/// and the checksum stands behind it.
///
/// Not thread-safe, and not meant to be: it lives inside the adapter actor.
final class ThinkDiagFrameReader {

    private var buffer: [UInt8] = []

    /// How many bytes have been thrown away as not-a-frame. Zero on a healthy
    /// link; anything else belongs in the technical log, because a reader that
    /// silently discards is a reader that hides a broken adapter.
    private(set) var discarded = 0

    /// Whatever has not yet formed a frame. Feeds the timeout path, which needs
    /// to say whether nothing arrived or half a frame did.
    var pending: Int { buffer.count }

    func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Throw away the buffer, so a late reply cannot be read as the answer to
    /// the next request. The counterpart of `LinkTransport.drain()`.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        discarded = 0
    }

    /// The next whole frame, or `nil` when more bytes are needed. Call until it
    /// returns `nil`: one notification can complete two frames.
    func next() -> ThinkDiagFrame? {
        while true {
            guard let start = preambleIndex() else {
                // A lone 0x55 at the very end may be the first half of the next
                // frame's preamble, so it is the one byte worth keeping.
                let keep = buffer.last == ThinkDiagFrame.preamble[0] ? 1 : 0
                discarded += buffer.count - keep
                buffer.removeFirst(buffer.count - keep)
                return nil
            }
            if start > 0 {
                discarded += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= ThinkDiagFrame.headerLength else { return nil }

            let declared = Int(buffer[4]) << 8 | Int(buffer[5])
            let total = ThinkDiagFrame.headerLength + declared + 1
            guard let tag = ThinkDiagTag(rawValue: UInt16(buffer[2]) << 8 | UInt16(buffer[3])),
                  declared >= ThinkDiagFrame.minBodyLength,
                  total <= ThinkDiagFrame.maxFrameLength
            else {
                skipFalseStart()
                continue
            }
            guard buffer.count >= total else { return nil }

            let body = buffer[ThinkDiagFrame.preamble.count..<(total - 1)]
            guard ThinkDiagFrame.checksum(body) == buffer[total - 1] else {
                skipFalseStart()
                continue
            }

            let payload = Data(buffer[(ThinkDiagFrame.headerLength + 2)..<(total - 1)])
            let frame = ThinkDiagFrame(tag: tag, seq: buffer[6], cmd: buffer[7], payload: payload)
            buffer.removeFirst(total)
            return frame
        }
    }

    /// Step over a preamble that did not begin a frame. Two bytes, so the
    /// search resumes past it rather than finding the same one again.
    private func skipFalseStart() {
        discarded += ThinkDiagFrame.preamble.count
        buffer.removeFirst(ThinkDiagFrame.preamble.count)
    }

    private func preambleIndex() -> Int? {
        guard buffer.count >= ThinkDiagFrame.preamble.count else { return nil }
        for i in 0...(buffer.count - ThinkDiagFrame.preamble.count) {
            if buffer[i] == ThinkDiagFrame.preamble[0], buffer[i + 1] == ThinkDiagFrame.preamble[1] {
                return i
            }
        }
        return nil
    }
}
