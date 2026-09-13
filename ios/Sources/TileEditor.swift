import SwiftUI

/// Editing one tile: how it is drawn, how big it is, what scale it is drawn
/// against, and where it sits.
///
/// The scale matters more than it looks. The profile's own ends come from the
/// Diagbox databases and are the range of the raw bytes, not of the reading:
/// engine speed is 0…65535 there, so a needle drawn against it never leaves
/// the first degree. A tile may therefore carry its own ends, and this is
/// where they are set.
struct TileEditor: View {

    let field: Readout
    /// Where this tile sits, to say whether it can move further.
    let position: Int
    let count: Int

    let onChange: (Tile) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    @State private var tile: Tile
    @State private var low: String
    @State private var high: String

    @Environment(\.dismiss) private var dismiss

    init(tile: Tile,
         field: Readout,
         position: Int,
         count: Int,
         onChange: @escaping (Tile) -> Void,
         onMove: @escaping (Int) -> Void,
         onDelete: @escaping () -> Void) {
        self.field = field
        self.position = position
        self.count = count
        self.onChange = onChange
        self.onMove = onMove
        self.onDelete = onDelete
        _tile = State(initialValue: tile)
        _low = State(initialValue: TileEditor.text(tile.low))
        _high = State(initialValue: TileEditor.text(tile.high))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Вид", selection: $tile.style) {
                        ForEach(Tile.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Размер", selection: $tile.size) {
                        ForEach(Tile.Size.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(field.label)
                }

                if field.isNumeric {
                    Section {
                        HStack {
                            Text("От")
                            TextField(number(field.low), text: $low)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("До")
                            TextField(number(field.high), text: $high)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Шкала ЭБУ") {
                            low = ""
                            high = ""
                        }
                        .disabled(low.isEmpty && high.isEmpty)
                    } header: {
                        Text("Шкала")
                    } footer: {
                        Text("Для шкалы и полосы. Пусто — как в профиле ЭБУ: "
                             + "\(number(field.low)) – \(number(field.high)).")
                    }
                }

                Section {
                    Button {
                        onMove(-1)
                        dismiss()
                    } label: {
                        Label("Сдвинуть назад", systemImage: "arrow.left")
                    }
                    .disabled(position <= 0)
                    Button {
                        onMove(1)
                        dismiss()
                    } label: {
                        Label("Сдвинуть вперёд", systemImage: "arrow.right")
                    }
                    .disabled(position >= count - 1)
                }

                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Убрать плитку", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Плитка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: -

    private func apply() {
        var edited = tile
        edited.low = TileEditor.value(low)
        edited.high = TileEditor.value(high)
        // Ends the wrong way round, or the same, would leave a gauge with
        // nothing to draw; treat that as "no ends of its own".
        if let a = edited.low, let b = edited.high, b <= a {
            edited.low = nil
            edited.high = nil
        }
        onChange(edited)
    }

    private func number(_ value: Double) -> String {
        String(format: "%.\(field.decimals)f", value)
    }

    private static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    /// A comma is what the Russian keyboard offers for a decimal point.
    private static func value(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return cleaned.isEmpty ? nil : Double(cleaned)
    }
}
