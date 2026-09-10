import XCTest

/// The standard OBD-II set, and the multi-PID reading that makes it fast.
///
/// The proprietary pages answer with 40-70 bytes, which BLE delivers one
/// 20-byte notification per connection event - about 240 ms for a big page. A
/// mode-01 answer for six PIDs fits in two notifications, so the whole point of
/// this path is asking for several readings at once. Which means the walk over
/// the answer has to be exactly right, and has to refuse rather than guess.
final class ObdTests: XCTestCase {

    private var bundle: Bundle { Bundle(for: ObdTests.self) }

    private func loadSet() throws -> ObdSet {
        try ObdSet.bundled(in: bundle)
    }

    // MARK: - the shared table

    func testTheBundledTableIsTheOneTheWebVersionUses() throws {
        let obd = try loadSet()
        XCTAssertEqual(obd.header.req, "7E0")
        XCTAssertEqual(obd.header.res, "7E8")
        XCTAssertEqual(obd.params.count, 21)

        let rpm = try XCTUnwrap(obd.byKey["RPM"])
        XCTAssertEqual(rpm.pid, "010C")
        XCTAssertEqual(rpm.code, "0C")
        XCTAssertEqual(rpm.marker, "410C", "mode 01 is answered by 0x41")
        XCTAssertEqual(rpm.length, 2)
        // 0x0A1F = 2591 quarter-revolutions = 647.75 rpm
        XCTAssertEqual(rpm.value(0x0A1F), 647.75, accuracy: 1e-9)

        let coolant = try XCTUnwrap(obd.byKey["Coolant"])
        XCTAssertEqual(coolant.value(90), 50, accuracy: 1e-9, "the standard's -40 offset")
    }

    // MARK: - requests

    /// The grouping is bounded by the size of the ANSWER, because this adapter
    /// corrupts one that spans CAN frames - see the regression below.
    func testPidsAreGroupedToFitOneCanFrame() throws {
        let obd = try loadSet()
        let groups = ObdReply.group(obd.params)

        for group in groups {
            let answer = 1 + group.reduce(0) { $0 + 1 + $1.wireLength }
            XCTAssertLessThanOrEqual(answer, ObdReply.frameBudget,
                                     "\(ObdReply.request(for: group)) would answer in \(answer) bytes")
        }
        XCTAssertEqual(groups.flatMap { $0 }.map(\.key), obd.params.map(\.key),
                       "grouping must not drop or reorder anything")
        XCTAssertGreaterThan(groups.count, 1)
    }

    /// A two-byte PID leaves room for one more single-byte one, not two.
    func testATwoBytePidTakesMoreOfTheFrame() throws {
        let obd = try loadSet()
        let rpm = try XCTUnwrap(obd.byKey["RPM"])          // 2 bytes
        let load = try XCTUnwrap(obd.byKey["Load"])        // 1
        let coolant = try XCTUnwrap(obd.byKey["Coolant"])  // 1

        // 1 + (1+2) + (1+1) = 6 fits; adding another (1+1) would make 8.
        XCTAssertEqual(ObdReply.group([rpm, load, coolant]).map(\.count), [2, 1])
        // 1 + 3 * (1+1) = 7 fits exactly.
        XCTAssertEqual(ObdReply.group([load, coolant, load]).count, 1)
    }

    func testARequestIsTheModeFollowedByEachCode() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant", "Speed"].compactMap { obd.byKey[$0] }
        // 01 + 0C (rpm) + 05 (coolant) + 0D (speed)
        XCTAssertEqual(ObdReply.request(for: group), "010C050D")
    }

    func testFallingBackToOnePidPerRequest() throws {
        let obd = try loadSet()
        let groups = ObdReply.group(Array(obd.params.prefix(3)), singly: true)
        XCTAssertEqual(groups.map(\.count), [1, 1, 1])
    }

    // MARK: - what the car actually answered

    /// Recorded on 2026-09-10. Six PIDs whose answer needs three CAN frames:
    /// the adapter merged it wrongly, duplicating the last frame shifted by a
    /// byte - 20 bytes where 14 were due. Reading it would have put five
    /// values in the wrong place, so it has to be refused, and the grouping
    /// above is what stops it being asked for in the first place.
    func testTheGarbledSixPidAnswerFromTheCarIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM", "Load", "Coolant", "IAT", "MAP", "Throttle"]
            .compactMap { obd.byKey[$0] }
        XCTAssertEqual(ObdReply.request(for: group), "010C04050F0B11")
        XCTAssertNil(ObdReply.walk("410C1140045505450F450B2C1128450F450B2C11",
                                   expecting: group),
                     "the tail is a shifted duplicate of the preceding frame")

        // And the same request would no longer be built: it needs 14 bytes.
        XCTAssertGreaterThan(ObdReply.group(group).count, 1)
    }

    /// Recorded in the same session: two PIDs whose answer fits one frame came
    /// back exactly right and were accepted.
    func testTheTwoPidAnswerFromTheCarIsRead() throws {
        let obd = try loadSet()
        let volt = try XCTUnwrap(obd.byKey["Volt"])
        let baro = try XCTUnwrap(obd.byKey["Baro"])
        XCTAssertEqual(ObdReply.request(for: [volt, baro]), "014233")

        let raws = try XCTUnwrap(ObdReply.walk("4142385E3356", expecting: [volt, baro]))
        XCTAssertEqual(raws["42"], 0x385E)
        XCTAssertEqual(raws["33"], 0x56)
        XCTAssertEqual(volt.value(0x385E), 14.43, accuracy: 1e-9, "14.43 V")
        XCTAssertEqual(baro.value(0x56), 86, accuracy: 1e-9, "86 kPa")
        XCTAssertEqual(ObdReply.group([volt, baro]).count, 1, "one frame, one request")
    }

    // MARK: - walking an answer

    func testSeveralReadingsAreTakenFromOneAnswer() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant", "Speed"].compactMap { obd.byKey[$0] }

        // 41 0C 0A1F 05 5A 0D 32
        let raws = try XCTUnwrap(ObdReply.walk("410C0A1F055A0D32", expecting: group))
        XCTAssertEqual(raws["0C"], 0x0A1F)
        XCTAssertEqual(raws["05"], 0x5A)
        XCTAssertEqual(raws["0D"], 0x32)
    }

    /// The ECU may answer only the first PID of a multi-PID request. Reading
    /// the rest from wherever they landed would be worse than not reading them.
    func testAnAnswerMissingPidsIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant", "Speed"].compactMap { obd.byKey[$0] }
        XCTAssertNil(ObdReply.walk("410C0A1F", expecting: group))
    }

    /// A PID answering with more bytes than the table expects desyncs
    /// everything after it, so the whole answer is thrown away.
    func testAnAnswerWithTrailingBytesIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant"].compactMap { obd.byKey[$0] }
        XCTAssertNil(ObdReply.walk("410C0A1F055AFF", expecting: group))
    }

    func testAnAnswerForAPidNobodyAskedForIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM"].compactMap { obd.byKey[$0] }
        XCTAssertNil(ObdReply.walk("410C0A1F0D32", expecting: group))
    }

    func testSomethingOtherThanModeOneIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM"].compactMap { obd.byKey[$0] }
        XCTAssertNil(ObdReply.walk("7F0112", expecting: group), "a negative response")
        XCTAssertNil(ObdReply.walk("", expecting: group))
    }

    /// What the car actually does. Measured on 2026-09-10: a six-PID request
    /// was answered in one exchange of 97 ms, and refused, because the ECU
    /// returns each PID as its own message rather than one message carrying
    /// six. Reading them singly instead cost 468 ms.
    func testPidsAnsweredAsSeparateConcatenatedMessages() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant", "Speed"].compactMap { obd.byKey[$0] }

        // 410C0A1F | 41055A | 410D32
        let raws = try XCTUnwrap(ObdReply.walk("410C0A1F41055A410D32", expecting: group))
        XCTAssertEqual(raws["0C"], 0x0A1F)
        XCTAssertEqual(raws["05"], 0x5A)
        XCTAssertEqual(raws["0D"], 0x32)
    }

    func testTheOrderOfConcatenatedMessagesDoesNotMatter() throws {
        let obd = try loadSet()
        let group = ["Speed", "RPM"].compactMap { obd.byKey[$0] }
        let raws = try XCTUnwrap(ObdReply.walk("410D3241 0C0A1F".replacingOccurrences(of: " ", with: ""),
                                               expecting: group))
        XCTAssertEqual(raws["0D"], 0x32)
        XCTAssertEqual(raws["0C"], 0x0A1F)
    }

    func testAConcatenatedAnswerMissingOnePidIsRefused() throws {
        let obd = try loadSet()
        let group = ["RPM", "Coolant", "Speed"].compactMap { obd.byKey[$0] }
        XCTAssertNil(ObdReply.walk("410C0A1F41055A", expecting: group))
    }

    /// PID 14 answers with two bytes - the sensor voltage and a fuel trim -
    /// and only the voltage is wanted. Reading one byte but stepping over one
    /// is what left both lambdas empty in the whole first drive log.
    func testAPidLongerThanTheValueReadFromItIsStillStepped() throws {
        let obd = try loadSet()
        let lambda = try XCTUnwrap(obd.byKey["O2S1"])
        XCTAssertEqual(lambda.length, 1, "only byte A is wanted")
        XCTAssertEqual(lambda.wireLength, 2, "but the PID answers with two")

        // Alone: the trailing trim byte must not be mistaken for junk.
        let single = try XCTUnwrap(ObdReply.walk("41140A20", expecting: [lambda]))
        XCTAssertEqual(single["14"], 0x0A)
        XCTAssertEqual(lambda.value(0x0A), 0.05, accuracy: 1e-9)

        // And in company: the PID after it must still land in the right place.
        let speed = try XCTUnwrap(obd.byKey["Speed"])
        let pair = try XCTUnwrap(ObdReply.walk("41140A2041 0D32".replacingOccurrences(of: " ", with: ""),
                                               expecting: [lambda, speed]))
        XCTAssertEqual(pair["14"], 0x0A)
        XCTAssertEqual(pair["0D"], 0x32, "not the trim byte")
    }

    func testASinglePidAnswerWalksToo() throws {
        let obd = try loadSet()
        let group = ["Volt"].compactMap { obd.byKey[$0] }
        let raws = try XCTUnwrap(ObdReply.walk("41421D2C", expecting: group))
        XCTAssertEqual(raws["42"], 0x1D2C)
        // 7468 mV
        XCTAssertEqual(group[0].value(0x1D2C), 7.468, accuracy: 1e-9)
    }
}
