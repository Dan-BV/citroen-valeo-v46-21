import Foundation

/// One live reading of a parameter.
struct Sample: Equatable {
    let value: Double
    /// The untouched reading, which enumerated fields need for their label.
    let raw: Int
    let at: Date
    let valid: Bool
}

/// A single point in a parameter's time series.
struct Point: Equatable {
    let at: Date
    let value: Double
}

/// A fault code exactly as the ECU reports it: the two-byte PSA identifier,
/// the failure-type byte a UDS module puts after it (empty on a KWP one), and
/// the status byte. What it *means* is the dictionary's business, not the
/// session's - see `DtcDictionary`.
struct Dtc: Equatable, Identifiable {
    let code: String
    let failureType: String
    let status: String

    init(code: String, failureType: String = "", status: String) {
        self.code = code
        self.failureType = failureType
        self.status = status
    }

    var id: String { code + failureType + status }

    /// How the code is written on screen: `$8001-11` for a UDS fault, `$0011`
    /// for a KWP one.
    var display: String {
        "$" + code + (failureType.isEmpty ? "" : "-" + failureType)
    }
}

struct IdentBlock: Identifiable {
    let title: String
    let rows: [(String, String)]

    var id: String { title }
}

enum ValueKind {
    case numeric
    case enumerated
}

extension Profile.Field {
    var kind: ValueKind { states == nil ? .numeric : .enumerated }

    /// Engineering units from an already-masked reading. The mask and shift are
    /// applied by `read`, which is where the bit-field order lives.
    func value(fromMasked raw: Int) -> Double {
        Double(raw) * scale + delta
    }

    func stateText(_ raw: Int) -> String {
        states?[String(raw)] ?? "?\(raw)"
    }
}
