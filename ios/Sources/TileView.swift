import Charts
import SwiftUI
import UIKit

/// One tile, drawn.
///
/// It reads `session.values[key]` and `session.history(of:seconds:)` and
/// nothing else - the same two things the parameter list and the graph screen
/// read. A tile never asks for a reading of its own, which is why putting a
/// parameter on a dashboard that is already in the list costs nothing at all:
/// no extra request, no extra column, no second copy in memory.
struct TileView: View {

    @ObservedObject var session: ElmSession
    let tile: Tile
    let field: Readout

    /// How much of a curve a graph tile shows.
    private static let window: TimeInterval = 60

    private var sample: Sample? { session.values[tile.key] }

    private var valid: Bool { sample?.valid == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: -

    private var header: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(field.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if unrecorded {
                // Added after the file was opened, so it is on screen but not
                // in the drive. Better said here than found missing later.
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("не пишется в этот заезд")
            }
        }
    }

    /// A recording is open and this parameter is not one of its columns.
    private var unrecorded: Bool {
        session.logURL != nil && !session.recordedKeys.contains(tile.key)
    }

    @ViewBuilder
    private var content: some View {
        switch tile.style {
        case .number:
            number
        case .gauge:
            if let range { gauge(range) } else { number }
        case .bar:
            if let range { bar(range) } else { number }
        case .graph:
            graph
        }
    }

    private var number: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(field.isNumeric ? 1 : 2)
                .minimumScaleFactor(0.4)
                .foregroundStyle(valid ? .primary : .secondary)
            if field.isNumeric, !field.unit.isEmpty {
                Text(field.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func gauge(_ range: ClosedRange<Double>) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Gauge(value: clamped(range), in: range) {
                EmptyView()
            } currentValueLabel: {
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(.accentColor)
            if !field.unit.isEmpty {
                Text(field.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func bar(_ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            number
            Gauge(value: clamped(range), in: range) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private var graph: some View {
        let points = session.history(of: tile.key, seconds: Self.window)
        if points.count < 2 {
            number
        } else {
            VStack(alignment: .leading, spacing: 4) {
                number
                Chart(points, id: \.at) { point in
                    LineMark(x: .value("Время", point.at),
                             y: .value(field.label, point.value))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: domain(points))
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: -

    /// The number alone; the unit is drawn beside it, and a text state stands
    /// in for both.
    private var text: String {
        guard let sample, sample.valid else { return "—" }
        if !field.isNumeric { return field.state(sample.raw) ?? "—" }
        return String(format: "%.\(field.decimals)f", sample.value)
    }

    /// The tile's own ends if it has them, otherwise the profile's - and
    /// nothing at all for a reading that is not a number or whose ends are the
    /// raw byte range rather than a scale. Then the tile falls back to showing
    /// the number, which is always honest.
    private var range: ClosedRange<Double>? {
        guard field.isNumeric else { return nil }
        let low = tile.low ?? field.low
        let high = tile.high ?? field.high
        guard high > low, high - low < 100_000 else { return nil }
        return low...high
    }

    private func clamped(_ range: ClosedRange<Double>) -> Double {
        guard let sample, sample.valid else { return range.lowerBound }
        return min(max(sample.value, range.lowerBound), range.upperBound)
    }

    private func domain(_ points: [Point]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        guard high > low else { return (low - 1)...(high + 1) }
        let pad = (high - low) * 0.1
        return (low - pad)...(high + pad)
    }
}
