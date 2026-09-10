import Foundation

/// What a screen needs to know about a reading.
///
/// A row and a graph want the same handful of facts about a parameter, and not
/// the byte layout around it. Kept as its own type because both of them read it
/// and neither should reach into the profile.
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

    /// How the value reads on screen: the text state if it has one, otherwise
    /// the number with its unit.
    func text(_ sample: Sample?) -> String {
        guard let sample, sample.valid else { return "—" }
        if !isNumeric { return state(sample.raw) ?? "—" }
        let number = String(format: "%.\(decimals)f", sample.value)
        return unit.isEmpty ? number : number + " " + unit
    }
}
