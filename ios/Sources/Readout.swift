import Foundation

/// What a screen needs to know about a reading, whichever set it came from.
///
/// The proprietary profile and the standard OBD-II table describe a parameter
/// differently - one has enumerated states and bit fields, the other only
/// linear formulas - but a row and a graph want the same handful of facts. This
/// keeps one list and one graph instead of a pair of each.
struct Readout: Identifiable {
    let key: String
    let label: String
    let unit: String
    let decimals: Int
    let low: Double
    let high: Double
    /// Enumerated readings have no curve worth drawing.
    let isNumeric: Bool
    /// The text a raw value stands for, when it stands for one.
    let state: (Int) -> String?

    var id: String { key }

    init(_ field: Profile.Field) {
        key = field.key
        label = field.label
        unit = field.unit
        decimals = field.decimals
        low = field.low
        high = field.high
        isNumeric = field.kind == .numeric
        state = { raw in field.states?[String(raw)] ?? "?\(raw)" }
    }

    init(_ param: ObdSet.Param) {
        key = param.key
        label = param.label
        unit = param.unit
        decimals = param.decimals
        low = param.low
        high = param.high
        isNumeric = true
        state = { _ in nil }
    }

    /// How the value reads on screen: the text state if it has one, otherwise
    /// the number with its unit.
    func text(_ sample: Sample?) -> String {
        guard let sample, sample.valid else { return "—" }
        if !isNumeric { return state(sample.raw) ?? "—" }
        let number = String(format: "%.\(decimals)f", sample.value)
        return unit.isEmpty ? number : number + " " + unit
    }
}
