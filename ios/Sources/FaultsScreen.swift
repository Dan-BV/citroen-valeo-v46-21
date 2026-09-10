import SwiftUI

/// Fault memory: `17 FF 00` to read, `14 FF 00` to clear.
///
/// The descriptions come from the profile's own 291 codes, mined from the
/// Diagbox database, so a code shows what the official tool would call it
/// rather than a generic table's guess.
///
/// Reading holds the same lock as the poll loop, so live values freeze for the
/// second it takes - the same behaviour as the Android app, and the reason the
/// screen says so while it works.
struct FaultsScreen: View {
    @ObservedObject var session: ElmSession

    @State private var faults: [Dtc]?
    @State private var failure: String?
    @State private var working = false
    @State private var confirmingClear = false
    @State private var cleared = false

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

            switch faults {
            case .none:
                if working {
                    Section { ProgressView("Чтение памяти неисправностей…") }
                }
            case .some(let list) where list.isEmpty:
                Section {
                    Label(cleared ? "Стёрто, память пуста" : "Ошибок нет",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            case .some(let list):
                Section("\(list.count) \(plural(list.count))") {
                    ForEach(list) { fault in
                        row(fault)
                    }
                }
            }

            Section {
                Button("Прочитать") { read() }
                    .disabled(working || !session.isConnected)
                Button("Стереть", role: .destructive) { confirmingClear = true }
                    .disabled(working || !session.isConnected || faults?.isEmpty != false)
            } footer: {
                Text("Пока идёт чтение, живые значения замирают: адаптер один, "
                     + "и очередь к нему общая с опросом.")
            }
        }
        .navigationTitle("Ошибки")
        .task {
            if faults == nil, session.isConnected { read() }
        }
        .confirmationDialog("Стереть память неисправностей?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Стереть", role: .destructive) { clear() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Коды и стоп-кадры будут потеряны безвозвратно. Если "
                 + "неисправность не устранена, она появится снова не сразу.")
        }
    }

    // MARK: -

    private func row(_ fault: Dtc) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(fault.code)
                    .font(.callout.monospaced().bold())
                Spacer()
                Text("статус " + fault.status)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(fault.label ?? "нет описания в профиле")
                .font(.callout)
                .foregroundStyle(fault.label == nil ? .secondary : .primary)
        }
    }

    private func plural(_ n: Int) -> String {
        switch (n % 100 / 10, n % 10) {
        case (1, _): return "ошибок"
        case (_, 1): return "ошибка"
        case (_, 2), (_, 3), (_, 4): return "ошибки"
        default: return "ошибок"
        }
    }

    private func read() {
        working = true
        failure = nil
        Task {
            do {
                faults = try await session.readDtc()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }

    private func clear() {
        working = true
        failure = nil
        Task {
            do {
                try await session.clearDtc()
                cleared = true
                // Read back rather than assume: a fault whose cause is still
                // present can reappear immediately, and that is worth seeing.
                faults = try await session.readDtc()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}
