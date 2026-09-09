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

/// A fault code as the ECU reports it, with the description from the profile.
struct Dtc: Equatable, Identifiable {
    let code: String
    let status: String
    let label: String?

    var id: String { code + status }
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
