import SwiftUI

/// The recordings on the phone: share them off, or delete them.
///
/// The same files are visible in the Files app under the app's folder, so this
/// screen is the convenience, not the only way out - which matters, because a
/// free signing certificate grants no iCloud container and there is no other
/// route off the device.
struct LogList: View {
    @ObservedObject var session: ElmSession

    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                Toggle("Писать лог поездки", isOn: Binding(
                    get: { session.logToFile },
                    set: { session.logToFile = $0 }
                ))
                if let url = session.logURL {
                    HStack {
                        Label("Идёт запись", systemImage: "record.circle")
                            .foregroundStyle(.red)
                        Spacer()
                        Text("\(session.loggedRows) строк")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Сохранить на диск сейчас") { session.flushLog() }
                    ShareLink(item: url) {
                        Text("Поделиться текущим")
                    }
                }
            } footer: {
                Text("Формат тот же, что у Android-версии: строка на цикл опроса, "
                     + "время в миллисекундах и локальный ISO, пустая ячейка — нет "
                     + "валидного чтения.")
            }

            Section("Файлы") {
                if files.isEmpty {
                    Text("Пока пусто").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.path) { url in
                    row(url)
                }
            }
        }
        .navigationTitle("Логи")
        .onAppear { reload() }
        .refreshable { reload() }
    }

    // MARK: -

    private func row(_ url: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                Text(details(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .swipeActions {
            Button("Удалить", role: .destructive) {
                try? FileManager.default.removeItem(at: url)
                reload()
            }
        }
    }

    private func details(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let when = values?.contentModificationDate
        let kb = Double(size) / 1024
        let stamp = when.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "—"
        return String(format: "%@ · %.0f КБ", stamp, kb)
    }

    private func reload() {
        files = CsvLogger.logs()
    }
}
