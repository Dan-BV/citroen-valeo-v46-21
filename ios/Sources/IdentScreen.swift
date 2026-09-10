import SwiftUI

/// What the ECU says about itself: hardware and software references, supplier,
/// diagnostic version, the ZI system code, download count, manufacturing date.
///
/// Three identification blocks, read with their own `21xx` requests. Their
/// fields are packed digits rather than measurements, so most are shown as the
/// raw hex the official tool shows - which is what makes them comparable with
/// a Diagbox printout at all.
struct IdentScreen: View {
    @ObservedObject var session: ElmSession

    @State private var blocks: [IdentBlock]?
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        List {
            if !session.isConnected {
                Section {
                    Label("Нет связи с ЭБУ — нажми «Пуск» на главном экране",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }

            if working, blocks == nil {
                Section { ProgressView("Чтение идентификации…") }
            }

            ForEach(blocks ?? []) { block in
                Section(block.title) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.1)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let blocks, blocks.isEmpty, !working {
                Section {
                    Text("ЭБУ не ответил ни на один блок идентификации")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Прочитать") { read() }
                    .disabled(working || !session.isConnected)
            }
        }
        .navigationTitle("ЭБУ")
        .task {
            if blocks == nil, session.isConnected { read() }
        }
    }

    private func read() {
        working = true
        failure = nil
        Task {
            do {
                blocks = try await session.readIdent()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}
