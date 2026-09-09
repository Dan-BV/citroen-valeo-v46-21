import SwiftUI

/// Everything that is setup rather than reading: which adapter, what the
/// profile holds, and the raw AT handshake for when the transport misbehaves.
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
                if !probe.lines.isEmpty || probe.failure != nil || probe.running {
                    handshakeSection
                }
                profileSection
            }
            .navigationTitle("Адаптер")
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
        Section("Выбранный") {
            if let adapter {
                VStack(alignment: .leading, spacing: 2) {
                    Text(adapter.name)
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Проверить рукопожатие") {
                    Task { await probe.run(adapter) }
                }
                .disabled(probe.running || session.isBusy)
                Button("Забыть", role: .destructive) {
                    session.disconnect()
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

    @ViewBuilder
    private var scanSection: some View {
        Section {
            Button(scanner.scanning ? "Остановить" : "Искать адаптер") { scanner.toggle() }
                .disabled(session.isBusy)
            if scanner.found.isEmpty {
                Text(scanner.scanning ? "Поиск…" : "Пока ничего не найдено")
                    .foregroundStyle(.secondary)
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

    /// Only useful when something is wrong: the session runs the same commands
    /// itself, but here each reply is visible with its round trip.
    @ViewBuilder
    private var handshakeSection: some View {
        Section("Рукопожатие") {
            if let failure = probe.failure {
                Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            ForEach(probe.lines) { line in
                HStack(alignment: .top) {
                    Text(line.command)
                        .font(.caption.monospaced())
                        .frame(width: 52, alignment: .leading)
                    Text(line.reply)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.answered ? .primary : .secondary)
                    Spacer()
                    Text("\(line.ms) мс")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Section("Профиль") {
            row("ЭБУ", "\(profile.ecu) · \(profile.platform)")
            row("CAN", "\(profile.can.req) → \(profile.can.res)")
            row("Страницы", "\(profile.pages.count)")
            row("Живые параметры", "\(profile.liveParamCount)")
            row("Поля идентификации", "\(profile.identFieldCount)")
            row("Коды неисправностей", "\(profile.dtc.count)")
            row("Сборка", "\(BuildInfo.version) · \(BuildInfo.commit)")
        }
    }

    private func choose(_ device: AdapterScanner.Found) {
        scanner.stop()
        let config = TransportConfig.ble(id: device.id, name: device.name)
        AdapterStore.save(config)
        adapter = config
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
