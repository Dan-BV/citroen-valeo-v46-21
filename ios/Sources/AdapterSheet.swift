import SwiftUI

/// Everything that is setup rather than reading: which adapter, the ECU
/// diagnostics that need a live link, and - folded away - what the profile
/// holds and which build this is.
///
/// Choosing a device checks it on the spot: the scan list folds, the AT
/// handshake runs, and the one line that matters lands under the adapter's
/// name - the chip's own banner, or why it did not answer. The exchange
/// itself is not shown; the session runs the same commands and the tech log
/// keeps every reply.
struct AdapterSheet: View {
    @ObservedObject var session: ElmSession
    let profile: Profile
    @Binding var adapter: TransportConfig?

    @StateObject private var scanner = AdapterScanner()
    @StateObject private var probe = ElmProbe()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                adapterSection
                scanSection
                Section("Диагностика") {
                    NavigationLink {
                        FaultsScreen(session: session)
                    } label: {
                        needsLink("Ошибки")
                    }
                    NavigationLink {
                        IdentScreen(session: session)
                    } label: {
                        needsLink("Идентификация ЭБУ")
                    }
                }
                aboutSection
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        scanner.stop()
                        probe.stop()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: -

    @ViewBuilder
    private var adapterSection: some View {
        Section("Адаптер") {
            if let adapter {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adapter.name)
                        verdictLine
                    }
                    Spacer()
                    // The check reruns on demand from right here; there is no
                    // separate button for it and no exchange to scroll to.
                    Button {
                        Task { await probe.run(adapter) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(probe.running || session.isBusy)
                    .accessibilityLabel("Проверить адаптер")
                }
                Button("Забыть", role: .destructive) {
                    session.disconnect()
                    probe.stop()
                    AdapterStore.forget()
                    self.adapter = nil
                }
                .disabled(session.isBusy)
            } else {
                Text("Не выбран — найди его ниже и нажми на строку")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The handshake in one line. Green with the chip's banner is the only
    /// state that means "go"; everything else says what is wrong.
    @ViewBuilder
    private var verdictLine: some View {
        switch probe.verdict {
        case .unchecked:
            if session.isBusy {
                Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Не проверен")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Проверяю…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .elm(banner):
            Label(banner, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .other(reply):
            Label("Отвечает, но не как ELM327: \(reply)", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .silent:
            Label("Связь есть, на команды не отвечает", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case let .failed(reason):
            Label("Не достучался: \(reason)", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section {
            Button(scanner.scanning ? "Остановить поиск" : "Искать адаптер") {
                scanner.toggle()
            }
            .disabled(session.isBusy)
            if scanner.found.isEmpty {
                if scanner.scanning {
                    Text("Поиск…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(scanner.found) { device in
                    Button {
                        choose(device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.id.uuidString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            Text(scanner.status)
        }
    }

    /// Out of the way, not gone: the profile numbers are what to quote when a
    /// value looks wrong, and the build is what to quote after an update.
    @ViewBuilder
    private var aboutSection: some View {
        Section {
            DisclosureGroup {
                row("ЭБУ", "\(profile.ecu) · \(profile.platform)")
                row("CAN", "\(profile.can.req) → \(profile.can.res)")
                row("Страницы", "\(profile.pages.count)")
                row("Живые параметры", "\(profile.liveParamCount)")
                row("Поля идентификации", "\(profile.identFieldCount)")
                row("Коды неисправностей", "\(profile.dtc.count)")
            } label: {
                row("О программе", "\(BuildInfo.version) · \(BuildInfo.commit)")
            }
        }
    }

    private func needsLink(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !session.isConnected {
                Text("нужна связь")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ device: AdapterScanner.Found) {
        scanner.reset()
        let config = TransportConfig.ble(id: device.id, name: device.name)
        AdapterStore.save(config)
        adapter = config
        // Prove the choice right away. Not while a session holds the link:
        // two connections to one adapter would fight over it.
        guard !session.isBusy else { return }
        Task { await probe.run(config) }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
