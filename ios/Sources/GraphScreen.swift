import Charts
import SwiftUI

/// One parameter's curve, live.
///
/// The Android version draws this by hand in ScalableChartView because a chart
/// library was not worth a dependency there; Swift Charts is part of the SDK,
/// so the pinch-to-scale behaviour comes down to the y range and the window.
///
/// The redraw is driven by `session.values`, which changes once per cycle: the
/// history itself is not published, so reading the live value here is what
/// makes the view pick the new points up.
struct GraphScreen: View {
    @ObservedObject var session: ElmSession
    let field: Readout

    enum Window: String, CaseIterable, Identifiable {
        case minute = "1 мин"
        case fiveMinutes = "5 мин"
        case everything = "всё"

        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .minute: return 60
            case .fiveMinutes: return 300
            case .everything: return nil
            }
        }
    }

    @State private var window: Window = .minute
    /// The ECU's own limits from the profile, instead of the data's range -
    /// useful to see how far a reading is from where it could go.
    @State private var fullScale = false

    var body: some View {
        let live = session.values[field.key]
        let points = windowed(session.history(of: field.key))

        return VStack(alignment: .leading, spacing: 12) {
            Text(current(live))
                .font(.largeTitle.monospacedDigit())
                .padding(.horizontal)

            if points.count < 2 {
                Spacer()
                Text(session.isConnected ? "Набор точек…" : "Нет данных")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                chart(points)
                summary(points)
                    .padding(.horizontal)
            }

            Picker("Окно", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Toggle("Шкала ЭБУ: \(number(field.low)) – \(number(field.high))", isOn: $fullScale)
                .padding(.horizontal)
                .font(.callout)
        }
        .padding(.vertical)
        .navigationTitle(field.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: -

    private func chart(_ points: [Point]) -> some View {
        Chart(points, id: \.at) { point in
            LineMark(x: .value("Время", point.at), y: .value(field.label, point.value))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: domain(points))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .frame(minHeight: 220)
        .padding(.horizontal)
    }

    private func summary(_ points: [Point]) -> some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let mean = values.reduce(0, +) / Double(values.count)
        return HStack {
            label("мин", low)
            Spacer()
            label("сред", mean)
            Spacer()
            label("макс", high)
            Spacer()
            label("точек", Double(points.count), decimals: 0)
        }
        .font(.caption)
    }

    private func label(_ name: String, _ value: Double, decimals: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundStyle(.secondary)
            Text(number(value, decimals: decimals)).monospacedDigit()
        }
    }

    private func windowed(_ points: [Point]) -> [Point] {
        guard let seconds = window.seconds, let last = points.last else { return points }
        let from = last.at.addingTimeInterval(-seconds)
        return points.filter { $0.at >= from }
    }

    private func domain(_ points: [Point]) -> ClosedRange<Double> {
        if fullScale, field.low < field.high {
            return field.low...field.high
        }
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        guard high > low else { return (low - 1)...(high + 1) }
        // A tenth of the range as breathing room, so the curve is not glued to
        // the frame.
        let pad = (high - low) * 0.1
        return (low - pad)...(high + pad)
    }

    private func current(_ sample: Sample?) -> String {
        guard let sample, sample.valid else { return "—" }
        if !field.isNumeric { return field.state(sample.raw) ?? "—" }
        let text = number(sample.value)
        return field.unit.isEmpty ? text : text + " " + field.unit
    }

    private func number(_ value: Double, decimals: Int? = nil) -> String {
        String(format: "%.\(decimals ?? field.decimals)f", value)
    }
}
