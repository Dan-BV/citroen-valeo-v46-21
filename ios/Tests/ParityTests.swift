import CryptoKit
import XCTest

/// Replays data/parity/golden.json - real frames recorded off the car, together
/// with the values the **raw** Diagbox database says they mean - through the
/// iOS decoder.
///
/// This is what keeps three independent implementations of the same byte maps
/// honest. A wrong offset, factor or bit mask in the Swift port, or in
/// tools/diagbox/make_profile.py, fails here instead of showing up as a wrong
/// number on a phone in a moving car.
final class ParityTests: XCTestCase {

    // MARK: - the fixture

    struct Golden: Decodable {
        struct Field: Decodable {
            let k: String
            let kind: String
        }

        struct Page: Decodable {
            let marker: String
            let fields: [Field]
        }

        struct Sample: Decodable {
            let p: String
            let h: String
            let r: [Int?]
            let v: [Value?]
        }

        /// A fixture value is a number, a string of hex digits, or absent for
        /// fields whose meaning is a text state.
        enum Value: Decodable, Equatable {
            case number(Double)
            case text(String)

            init(from decoder: Decoder) throws {
                let one = try decoder.singleValueContainer()
                if let d = try? one.decode(Double.self) {
                    self = .number(d)
                } else {
                    self = .text(try one.decode(String.self))
                }
            }
        }

        let source: String
        let profileSha256: String
        let pages: [String: Page]
        let samples: [Sample]

        enum CodingKeys: String, CodingKey {
            case source
            case profileSha256 = "profile_sha256"
            case pages
            case samples
        }
    }

    private var bundle: Bundle { Bundle(for: ParityTests.self) }

    private func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext),
                                "\(name).\(ext) is not in the test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: - tests

    /// The fixture only means anything against the profile it was built from.
    func testFixtureMatchesTheBundledProfile() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: try resource("golden", "json"))
        let digest = SHA256.hash(data: try resource("v46_21_profile", "json"))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(golden.profileSha256, hex,
                       "regenerate the fixture: python tools/parity/make_golden.py")
    }

    func testRecordedFramesDecodeToTheExpectedValues() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: try resource("golden", "json"))
        let profile = try Profile.bundled(in: bundle)

        let pages = Dictionary(uniqueKeysWithValues:
            profile.pages.compactMap { page in page.id.map { ($0, page) } })

        var checked = 0
        for sample in golden.samples {
            let page = try XCTUnwrap(pages[sample.p], "page \(sample.p) is not in the profile")
            let spec = try XCTUnwrap(golden.pages[sample.p])
            XCTAssertEqual(page.marker, spec.marker, "page \(sample.p) marker")

            let clean = Frames.clean(sample.h)
            let byKey = Dictionary(uniqueKeysWithValues: page.params.map { ($0.key, $0) })

            for (i, want) in spec.fields.enumerated() {
                let at = "\(sample.p)/\(want.k)"
                let field = try XCTUnwrap(byKey[want.k], "\(at) is not in the profile")
                let got = field.read(clean, marker: page.marker)

                guard let wantRaw = sample.r[i] else {
                    XCTAssertNil(got, "\(at) should not have decoded")
                    continue
                }
                let (raw, reading) = try XCTUnwrap(got, "\(at) failed to decode")
                XCTAssertEqual(raw, wantRaw, "\(at) raw")

                switch (reading, sample.v[i]) {
                case let (.number(got), .some(.number(want))):
                    // The fixture rounds to four decimals, the app does not.
                    XCTAssertEqual(got, want, accuracy: 5e-5, "\(at) value")
                case let (.hex(got), .some(.text(want))):
                    XCTAssertEqual(got, want, "\(at) digits")
                case let (.state(got, _), .none):
                    XCTAssertEqual(got, wantRaw, "\(at) state")
                default:
                    XCTFail("\(at): kind mismatch, decoded \(reading), fixture has "
                            + String(describing: sample.v[i]))
                }
                checked += 1
            }
        }

        // Guards against a fixture that silently decoded into nothing.
        XCTAssertGreaterThan(checked, 10_000, "the fixture looks empty")
        print("parity: \(checked) field readings over \(golden.samples.count) frames from \(golden.source)")
    }

    /// The recorded frames come from a Bluetooth sniff and carry no ELM
    /// formatting, so the multi-frame handling is checked separately - it is
    /// the part that silently corrupts everything after the first frame when it
    /// goes wrong.
    func testCleanStripsFramingAndLengthLines() {
        let reply = "03B\r0:61FF044F8F4F\r1:50FFFFFF0000\r\r>"
        XCTAssertEqual(Frames.clean(reply), "61FF044F8F4F50FFFFFF0000")
    }

    func testCleanKeepsSingleFrameRepliesAndUppercases() {
        XCTAssertEqual(Frames.clean("61 ff 04 4f\r\r>"), "61FF044F")
    }

    /// A standalone hex line is only a length header when the reply is framed;
    /// on a single-frame answer it is payload.
    func testCleanKeepsShortLinesWhenTheReplyIsNotFramed() {
        XCTAssertEqual(Frames.clean("41\r0C1AF8\r>"), "410C1AF8")
    }

    func testExtractReadsMSBFirstFromTheMarker() {
        // Engine speed 04 4F = 1103 rpm, two bytes after the 61FF marker.
        let clean = "61FF044F8F50"
        XCTAssertEqual(Frames.extract(clean, marker: "61FF", offset: 2, length: 2), 0x044F)
        XCTAssertEqual(Frames.extractHex(clean, marker: "61FF", offset: 2, length: 2), "044F")
        XCTAssertNil(Frames.extract(clean, marker: "61FF", offset: 40, length: 2))
        XCTAssertNil(Frames.extract(clean, marker: "61CF", offset: 2, length: 2))
    }

    /// The recording cannot cover this: the byte those two bit fields live in
    /// reads 0x08 in all 3052 recorded CA frames, so both a right and a wrong
    /// extraction order come out the same. TYPE_BOITE_VITESSES has mask 3 and
    /// shift 6, so masking before shifting makes it identically zero on any
    /// byte - which is what this checks, with the top bits actually set.
    func testBitFieldsShiftBeforeMasking() throws {
        let profile = try Profile.bundled(in: bundle)
        let page = try XCTUnwrap(profile.pages.first { $0.id == "CA" })
        let gearbox = try XCTUnwrap(page.params.first { $0.key == "TYPE_BOITE_VITESSES" })
        let gear = try XCTUnwrap(page.params.first { $0.key == "RAPPORT_ENGAGE" })
        XCTAssertEqual(gearbox.mask, 3)
        XCTAssertEqual(gearbox.shift, 6)

        // A frame whose byte at the pair's offset is 0xC8: top bits 11, low
        // bits 001000.
        var bytes = [UInt8](repeating: 0, count: gearbox.offset + 1)
        bytes[0] = 0x61
        bytes[1] = 0xFF
        bytes[gearbox.offset] = 0xC8
        let frame = bytes.map { String(format: "%02X", $0) }.joined()

        let (rawGearbox, _) = try XCTUnwrap(gearbox.read(frame, marker: page.marker))
        XCTAssertEqual(rawGearbox, 3, "0xC8 >> 6 & 3 = 3; masking first would give 0")

        let (rawGear, _) = try XCTUnwrap(gear.read(frame, marker: page.marker))
        XCTAssertEqual(rawGear, 8, "mask 63, shift 0: 0xC8 & 63 = 8")
    }

    func testErrorRepliesAreRecognised() {
        XCTAssertTrue(Frames.isError("NO DATA"))
        XCTAssertTrue(Frames.isError("?"))
        XCTAssertTrue(Frames.isError("CAN ERROR"))
        XCTAssertFalse(Frames.isError("61FF044F"))
    }
}
