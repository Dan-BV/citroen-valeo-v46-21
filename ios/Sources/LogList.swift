import SwiftUI

/// The recordings on the phone, shown as drives: share them off, or delete
/// them.
///
/// Two kinds of file per drive. `fap_log_` is the drive - one row per cycle,
/// one column per parameter, the same format the Android app wrote so it drops
/// straight into `data/logs/`. `fap_tech_` is the measurement - one row per
/// adapter exchange with the reply length, the number of BLE pieces it arrived
/// in and the round trip, which is what settles where the cycle time goes.
/// `Drive` pairs them, and a drive is shared as both files at once.
///
/// The same files are visible in the Files app under the app's folder, so this
/// screen is the convenience, not the only way out - which matters, because a
/// free signing certificate grants no iCloud container and there is no other
/// route off the device.
struct LogList: View {
    @ObservedObject var session: ElmSession

    @State private var drives: [Drive] = []
    @State private var selection = Set<URL>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmDelete = false

    var body: some View {
        List(selection: $selection) {
            recordingSection
            if drives.isEmpty {
                Section("Заезды") {
                    Text("Пока пусто").foregroundStyle(.secondary)
                }
            }
            ForEach(days, id: \.day) { day in
                Section(title(day.day)) {
                    ForEach(day.drives) { drive in
                        row(drive)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Логи")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !drives.isEmpty {
                    Button(editMode.isEditing ? "Готово" : "Выбрать") {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                            if !editMode.isEditing { selection.removeAll() }
                        }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(items: selectedURLs) {
                        Label(shareTitle, systemImage: "square.and.arrow.up")
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Button("Удалить", role: .destructive) { confirmDelete = true }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .confirmationDialog("Удалить \(selected.count) заезд(ов)?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { delete(selected) }
        }
        .onAppear {
            // What is buffered goes to disk first, so the drive under way can
            // be shared from here mid-drive.
            session.flushLog()
            reload()
        }
        .refreshable { reload() }
    }

    // MARK: - recording

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
        } header: {
            Text("Запись")
        } footer: {
            Text("Замер нужен, чтобы понять, во что уходит время цикла: он пишет "
                 + "длину ответа, число BLE-порций и время каждой команды. "
                 + "Один прогон отвечает на это числом.")
        }
        .selectionDisabled()
    }

    // MARK: - drives

    private struct Day {
        let day: Date
        let drives: [Drive]
    }

    /// Newest day first, newest drive first within it.
    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: drives) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { Day(day: $0, drives: grouped[$0] ?? []) }
    }

    private func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    private func row(_ drive: Drive) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(drive.start.formatted(date: .omitted, time: .shortened))
                        .font(.headline.monospacedDigit())
                    if isCurrent(drive) {
                        Label("идёт запись", systemImage: "record.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text(details(drive))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !editMode.isEditing {
                ShareLink(items: drive.urls) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Отправить заезд")
            }
        }
        .tag(drive.id)
        .swipeActions {
            if !isCurrent(drive) {
                Button("Удалить", role: .destructive) { delete([drive]) }
            }
        }
    }

    /// Length, weight and what is in it: the weight because the files leave
    /// by messenger, the contents because a drive can be missing one file.
    private func details(_ drive: Drive) -> String {
        var parts = [length(drive.duration), size(drive.bytes)]
        var kinds: [String] = []
        if drive.hasLog { kinds.append("поездка") }
        if drive.hasTech { kinds.append("замер") }
        parts.append(kinds.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func length(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "меньше минуты" }
        return Duration.seconds(Int(seconds))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// By name, not URL: the directory listing and the recorder can spell the
    /// same path differently, and the stamp makes the name unique anyway.
    private func isCurrent(_ drive: Drive) -> Bool {
        let open = [session.logURL, session.techURL].compactMap { $0?.lastPathComponent }
        return drive.urls.contains { open.contains($0.lastPathComponent) }
    }

    // MARK: - selection

    private var selected: [Drive] {
        drives.filter { selection.contains($0.id) }
    }

    private var selectedURLs: [URL] {
        selected.flatMap(\.urls)
    }

    private var shareTitle: String {
        let urls = selectedURLs
        guard !urls.isEmpty else { return "Отправить" }
        let bytes = selected.reduce(0) { $0 + $1.bytes }
        return "Отправить · \(files(urls.count)) · \(size(bytes))"
    }

    private func files(_ n: Int) -> String {
        let last = n % 10, tens = n % 100
        if last == 1, tens != 11 { return "\(n) файл" }
        if (2...4).contains(last), !(12...14).contains(tens) { return "\(n) файла" }
        return "\(n) файлов"
    }

    /// The drive under way is skipped: its files are still being written.
    private func delete(_ drives: [Drive]) {
        for url in drives.filter({ !isCurrent($0) }).flatMap(\.urls) {
            try? FileManager.default.removeItem(at: url)
        }
        selection.removeAll()
        reload()
    }

    private func reload() {
        drives = Drive.onDisk()
    }
}
