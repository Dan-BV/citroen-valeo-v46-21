import SwiftUI

/// The recordings on the phone: share them off, or delete them.
///
/// Two kinds. `fap_log_` is the drive - one row per cycle, one column per
/// parameter, the same format the Android app writes so it drops straight into
/// `data/logs/`. `fap_tech_` is the measurement - one row per adapter exchange
/// with the reply length, the number of BLE pieces it arrived in and the round
/// trip, which is what settles where the cycle time actually goes.
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
            recordingSection
            filesSection
        }
        .navigationTitle("Логи")
        .onAppear { reload() }
        .refreshable { reload() }
    }

    // MARK: -

    @ViewBuilder
    private var recordingSection: some View {
        Section {
            Toggle("Лог поездки", isOn: Binding(
                get: { session.logToFile },
                set: { session.logToFile = $0 }
            ))
            Toggle("Технический замер", isOn: Binding(
                get: { session.techToFile },
                set: { session.techToFile = $0 }
            ))
            if session.logURL != nil || session.techURL != nil {
                Button("Сохранить на диск сейчас") { session.flushLog() }
            }
            if let url = session.logURL {
                current("Поездка", url, rows: session.loggedRows)
            }
            if let url = session.techURL {
                current("Замер", url, rows: session.techRows)
            }
        } header: {
            Text("Запись")
        } footer: {
            Text("Замер нужен, чтобы понять, во что уходит время цикла: он пишет "
                 + "длину ответа, число BLE-порций и время каждой команды. "
                 + "Один прогон отвечает на это числом.")
        }
    }

    private func current(_ name: String, _ url: URL, rows: Int) -> some View {
        HStack {
            Label(name, systemImage: "record.circle")
                .foregroundStyle(.red)
            Spacer()
            Text("\(rows)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section("Файлы") {
            if files.isEmpty {
                Text("Пока пусто").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.path) { url in
                row(url)
            }
        }
    }

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
        let kind = url.lastPathComponent.hasPrefix(TechLog.prefix) ? "замер" : "поездка"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let when = CsvFile.modified(url).formatted(date: .abbreviated, time: .shortened)
        return String(format: "%@ · %@ · %.0f КБ", kind, when, Double(size) / 1024)
    }

    private func reload() {
        files = (CsvLogger.logs() + TechLog.logs())
            .sorted { CsvFile.modified($0) > CsvFile.modified($1) }
    }
}
