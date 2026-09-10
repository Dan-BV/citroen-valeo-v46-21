import XCTest

/// The `55aa` codec, against frames the official ThinkDiag app actually put on
/// the wire.
///
/// Round-tripping a codec against itself proves nothing about a protocol that
/// was reverse-engineered, so the frames below are real, copied out of the
/// 2026-09-10 captures. The full corpus - 12 040 frames - is checked by
/// `tools/thinkdiag/verify_frames.py`, which cannot run here because the
/// captures carry the adapter's licence blob and stay off the repository.
///
/// The rest of the tests cover what a BLE stream does to frames: cuts them in
/// pieces that ignore frame boundaries, joins two into one notification, and
/// occasionally starts mid-frame.
final class ThinkDiagFrameTests: XCTestCase {

    // MARK: - real frames

    /// `21/03`, the adapter's identity query. The shortest frame there is, and
    /// the one that pins down what `len` counts: it declares 3 for `seq`, `cmd`
    /// and a single payload byte.
    func testTheIdentityRequestParsesAsCaptured() {
        let frame = parseOne("55aaf0f800035f210376")
        XCTAssertEqual(frame?.tag, .toAdapter)
        XCTAssertEqual(frame?.seq, 0x5f)
        XCTAssertEqual(frame?.cmd, 0x21)
        XCTAssertEqual(frame?.sub, 0x03)
        XCTAssertEqual(frame?.payload, hex("03"))
    }

    /// Its reply: 71 payload bytes, the length-prefixed strings the handshake
    /// will read. A reply the codec gets wrong by one byte would still decode
    /// the first string and lose every one after it.
    func testTheIdentityReplyParsesAsCaptured() {
        let frame = parseOne(identityReply)
        XCTAssertEqual(frame?.tag, .fromAdapter)
        XCTAssertEqual(frame?.seq, 0x5f)
        XCTAssertEqual(frame?.cmd, 0x61)
        XCTAssertEqual(frame?.payload.count, 71)
        XCTAssertEqual(
            frame?.payload,
            hex("""
                03001932653264353333353337333633363133346533383336333200000d3937393836\
                3534393730333700000a56312e30302e3030300000093230323630313330000003313300
                """)
        )
    }

    /// `21/05`, versions. Kept because its payload ends in the model string:
    /// if the codec ever mislays the tail of a frame this is where it shows.
    func testTheVersionReplyCarriesTheModelName() {
        let frame = parseOne(versionReply)
        XCTAssertEqual(frame?.sub, 0x05)
        let text = String(decoding: frame?.payload ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("diagmini\u{0}"), "got \(text)")
    }

    /// Every real frame must survive being taken apart and put back together,
    /// checksum included - that is the half of the codec the captures cannot
    /// prove on their own, because they only ever show the adapter's arithmetic
    /// and never ours.
    func testCapturedFramesReEncodeByteForByte() {
        for wire in [
            "55aaf0f800035f210376",
            "55aaf0f800032d210502",
            "55aaf0f8000336212a36",
            "55aaf8f0000436612a0071",
            identityReply,
            versionReply,
        ] {
            XCTAssertEqual(parseOne(wire)?.encoded, hex(wire), "re-encoding \(wire)")
        }
    }

    /// A reply is the answer to a request when it echoes the id and sets the
    /// reply bit. Both captured pairs, then the three ways it can be wrong.
    func testAReplyIsRecognisedByItsIdAndCommand() {
        let identity = parseOne("55aaf0f800035f210376")!
        let versions = parseOne("55aaf0f800032d210502")!

        XCTAssertTrue(parseOne(identityReply)!.answers(identity))
        XCTAssertTrue(parseOne(versionReply)!.answers(versions))

        // The captured session ran the counter round ten times, so the id on
        // its own is not enough: this is the other page's answer.
        XCTAssertFalse(parseOne(versionReply)!.answers(identity))
        XCTAssertFalse(
            ThinkDiagFrame(tag: .fromAdapter, seq: 0x5f, cmd: 0x67).answers(identity),
            "a 27/01 answer is not a 21/03 answer"
        )
        XCTAssertFalse(
            ThinkDiagFrame(tag: .toAdapter, seq: 0x5f, cmd: 0x61).answers(identity),
            "our own frame echoed back is not an answer"
        )
    }

    // MARK: - building

    func testARequestIsBuiltWithTheCapturedChecksum() {
        let frame = ThinkDiagFrame.request(seq: 0x5f, cmd: 0x21, payload: hex("03"))
        XCTAssertEqual(frame.encoded, hex("55aaf0f800035f210376"))
    }

    /// No payload is legal - `len` bottoms out at the two bytes of `seq` and
    /// `cmd` - and the encoder must not write a length of zero.
    func testAnEmptyPayloadStillDeclaresTwoBytes() {
        let wire = ThinkDiagFrame.request(seq: 0x07, cmd: 0x21).encoded
        XCTAssertEqual(wire.count, 9)
        XCTAssertEqual([wire[4], wire[5]], [0x00, 0x02])
        XCTAssertEqual(parseOne(wire), ThinkDiagFrame.request(seq: 0x07, cmd: 0x21))
    }

    /// The length field is two bytes because the licence frame needs them: the
    /// widest frame in the capture is 1636 bytes.
    func testALongPayloadFillsBothLengthBytes() {
        let payload = Data(repeating: 0xa5, count: 1627)
        let frame = ThinkDiagFrame.request(seq: 0x05, cmd: 0x27, payload: payload)
        let wire = frame.encoded
        XCTAssertEqual(wire.count, 1636)
        XCTAssertEqual([wire[4], wire[5]], [0x06, 0x5d], "1629 big-endian")
        XCTAssertEqual(parseOne(wire), frame)
    }

    // MARK: - ids

    /// Counting is all the adapter asks of the id, and the captured session
    /// wrapped it ten times without complaint.
    func testIdsCountAndWrapThroughZero() {
        var seq = ThinkDiagSequence(startingAt: 0xfe)
        XCTAssertEqual([seq.next(), seq.next(), seq.next(), seq.next()], [0xfe, 0xff, 0x00, 0x01])
    }

    func testIdsStartWhereTheOfficialAppStarts() {
        var seq = ThinkDiagSequence()
        XCTAssertEqual([seq.next(), seq.next()], [1, 2])
    }

    // MARK: - reassembly

    /// The reason the reader exists. This adapter's notifications carry 93
    /// bytes and 672 of the captured frames are longer than that, so a frame
    /// arrives in pieces that know nothing about where it ends.
    func testAFrameArrivingInNotificationSizedPiecesIsAssembled() {
        let frame = ThinkDiagFrame(
            tag: .fromAdapter, seq: 0x12, cmd: 0x67,
            payload: Data((0..<400).map { UInt8($0 % 251) })
        )
        let reader = ThinkDiagFrameReader()
        let pieces = Chunker.chunks(frame.encoded, size: 93)
        XCTAssertEqual(pieces.count, 5, "otherwise this test is not testing reassembly")

        for piece in pieces.dropLast() {
            reader.append(piece)
            XCTAssertNil(reader.next(), "half a frame must not be handed out")
        }
        reader.append(pieces.last!)
        XCTAssertEqual(reader.next(), frame)
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.discarded, 0, "nothing here was rubbish")
    }

    /// Split at every offset there is. A boundary in the length field or in the
    /// middle of the checksum is the kind of thing that works until it does not.
    func testAFrameSurvivesBeingSplitAtEveryOffset() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 0x33, cmd: 0x61,
                                   payload: hex("0500ab0102030405"))
        let wire = frame.encoded
        for cut in 1..<wire.count {
            let reader = ThinkDiagFrameReader()
            reader.append(wire.prefix(cut))
            XCTAssertNil(reader.next(), "cut at \(cut) yielded a frame too early")
            reader.append(wire.suffix(from: cut))
            XCTAssertEqual(reader.next(), frame, "cut at \(cut)")
            XCTAssertEqual(reader.discarded, 0, "cut at \(cut)")
        }
    }

    /// The other direction: the adapter answers faster than we read, and two
    /// frames turn up in one notification.
    func testTwoFramesInOnePieceComeOutSeparately() {
        let first = ThinkDiagFrame(tag: .fromAdapter, seq: 1, cmd: 0x67, payload: hex("01000f"))
        let second = ThinkDiagFrame(tag: .fromAdapter, seq: 2, cmd: 0x67, payload: hex("01ff00"))
        let reader = ThinkDiagFrameReader()
        reader.append(first.encoded + second.encoded)
        XCTAssertEqual(reader.next(), first)
        XCTAssertEqual(reader.next(), second)
        XCTAssertNil(reader.next())
    }

    /// A `27/01` reply carries the ECU's answer as a nested frame of the same
    /// shape, which is why 7778 payloads in the capture contain the bytes
    /// `55aa`. A reader that looked for the next preamble instead of trusting
    /// `len` would cut this frame in half and lose the rest of the page.
    ///
    /// The nested frame here is made harder than any in the capture: it carries
    /// a valid tag too, so only the length and the checksum can save it.
    func testAPreambleInsideThePayloadIsJustPayload() {
        let nested = ThinkDiagFrame(tag: .fromAdapter, seq: 0x40, cmd: 0x61,
                                    payload: hex("deadbeef")).encoded
        let outer = ThinkDiagFrame(tag: .fromAdapter, seq: 0x38, cmd: 0x67,
                                   payload: hex("010000") + nested + hex("0e0000df"))
        let reader = ThinkDiagFrameReader()
        reader.append(outer.encoded)
        XCTAssertEqual(reader.next(), outer)
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.discarded, 0)
    }

    // MARK: - resynchronisation

    /// Connecting to an adapter that is already talking, or losing bytes to a
    /// dropped notification: the stream starts in the middle of a frame and the
    /// next whole one still has to be found.
    func testRubbishBeforeAFrameIsThrownAwayAndCounted() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 9, cmd: 0x61, payload: hex("1100"))
        let reader = ThinkDiagFrameReader()
        reader.append(hex("aabbcc55ddee") + frame.encoded)
        XCTAssertEqual(reader.next(), frame)
        XCTAssertEqual(reader.discarded, 6)
    }

    /// A preamble with a tag that is neither direction cannot begin a frame.
    /// This is the cheap test, and in the capture it alone rejects every one of
    /// the 7778 false starts.
    func testAPreambleWithAnUnknownTagIsSkipped() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 4, cmd: 0x67, payload: hex("01000f"))
        let reader = ThinkDiagFrameReader()
        reader.append(hex("55aa0b08ca40143762") + frame.encoded)
        XCTAssertEqual(reader.next(), frame)
        XCTAssertEqual(reader.discarded, 9)
    }

    /// A frame whose checksum does not add up is not handed on: it would be
    /// read as a page of data, and wrong data is worse than none.
    func testACorruptFrameIsDroppedAndTheNextOneStillArrives() {
        let good = ThinkDiagFrame(tag: .fromAdapter, seq: 7, cmd: 0x61, payload: hex("1700"))
        var corrupt = Array(good.encoded)
        corrupt[corrupt.count - 1] ^= 0xff

        let reader = ThinkDiagFrameReader()
        reader.append(Data(corrupt) + good.encoded)
        XCTAssertEqual(reader.next(), good)
        XCTAssertEqual(reader.discarded, corrupt.count, "the whole bad frame, not part of it")
    }

    /// A corrupt length field would otherwise have the reader waiting for bytes
    /// that are never coming, and the session would stall rather than fail.
    func testAnAbsurdLengthDoesNotStallTheReader() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 5, cmd: 0x67, payload: hex("01ff00"))
        let reader = ThinkDiagFrameReader()
        reader.append(hex("55aaf8f0ffff0561") + frame.encoded)
        XCTAssertEqual(reader.next(), frame)
        XCTAssertTrue(reader.discarded > 0)
    }

    /// A length under two claims a frame with no command in it.
    func testALengthTooSmallToHoldACommandIsSkipped() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 6, cmd: 0x61, payload: hex("2a00"))
        let reader = ThinkDiagFrameReader()
        reader.append(hex("55aaf8f0000100") + frame.encoded)
        XCTAssertEqual(reader.next(), frame)
    }

    /// A `0x55` that ends a notification is half a preamble, not rubbish: drop
    /// it and the frame that follows can never be read.
    func testAPreambleSplitAcrossTwoPiecesIsNotLost() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 8, cmd: 0x61, payload: hex("1800"))
        let wire = frame.encoded
        let reader = ThinkDiagFrameReader()
        reader.append(wire.prefix(1))
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.pending, 1, "the 0x55 has to be kept")
        reader.append(wire.dropFirst())
        XCTAssertEqual(reader.next(), frame)
        XCTAssertEqual(reader.discarded, 0)
    }

    /// `reset` is what a new request calls, so a late reply cannot be read as
    /// its answer.
    func testResetThrowsAwayWhateverWasBuffered() {
        let frame = ThinkDiagFrame(tag: .fromAdapter, seq: 3, cmd: 0x67, payload: hex("010089"))
        let reader = ThinkDiagFrameReader()
        reader.append(frame.encoded.dropLast())
        reader.reset()
        XCTAssertEqual(reader.pending, 0)
        XCTAssertEqual(reader.discarded, 0)

        reader.append(frame.encoded)
        XCTAssertEqual(reader.next(), frame, "and the reader still works afterwards")
    }

    // MARK: - captured frames, and a hex helper

    private let identityReply = """
        55aaf8f000495f6103001932653264353333353337333633363133346533383336333200000d3937\
        3938363534393730333700000a56312e30302e30303000000932303236303133300000033133\
        0062
        """

    private let versionReply = """
        55aaf8f0002c2d6105000a56312e32332e3030340000075632332e3035000007\
        5631302e3034000009646961676d696e690035
        """

    private func hex(_ text: String) -> Data {
        let digits = Array(text.filter { !$0.isWhitespace })
        XCTAssertEqual(digits.count % 2, 0, "odd number of hex digits")
        var out = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count - 1, by: 2) {
            guard let byte = UInt8(String(digits[i...(i + 1)]), radix: 16) else {
                XCTFail("not hex: \(String(digits[i...(i + 1)]))")
                return Data()
            }
            out.append(byte)
        }
        return out
    }

    private func parseOne(_ wire: String) -> ThinkDiagFrame? {
        parseOne(hex(wire))
    }

    private func parseOne(_ wire: Data) -> ThinkDiagFrame? {
        let reader = ThinkDiagFrameReader()
        reader.append(wire)
        let frame = reader.next()
        XCTAssertNil(reader.next(), "one frame in, one frame out")
        XCTAssertEqual(reader.pending, 0, "the whole frame should have been consumed")
        return frame
    }
}
