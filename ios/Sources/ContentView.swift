import SwiftUI

/// Skeleton screen, one step ahead of the session port: it proves the shared
/// generated profile parses on iOS, that CoreBluetooth sees the adapter, and
/// that the adapter answers the AT prefix of the ECU session.
struct ContentView: View {
    @StateObject private var scanner = AdapterScanner()
    @StateObject private var probe = ElmProbe()
    @State private var profile: Result<Profile, Error>?
    @State private var adapter: TransportConfig? = AdapterStore.load()

    var body: some View {
        NavigationStack {
            List {
                profileSection
                adapterSection
                if !probe.lines.isEmpty || probe.failure != nil || probe.running {
                    handshakeSection
                }
                scanSection
            }
            .navigationTitle("Valeo V46.21")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(BuildInfo.version) · \(BuildInfo.commit)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            if profile == nil {
                profile = Result { try Profile.bundled() }
            }
        }
    }

    // MARK: - sections

    @ViewBuilder
    private var profileSection: some View {
        Section("Профиль") {
            switch profile {
            case .none:
                ProgressView()
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            case .success(let p):
                row("ЭБУ", "\(p.ecu) · \(p.platform)")
                row("CAN", "\(p.can.req) → \(p.can.res)")
                row("Страницы", "\(p.pages.count)")
                row("Живые параметры", "\(p.liveParamCount)")
                row("Поля идентификации", "\(p.identFieldCount)")
                row("Коды неисправностей", "\(p.dtc.count)")
            }
        }
    }

    @ViewBuilder
    private var adapterSection: some View {
        Section("Адаптер") {
            if let adapter {
                HStack {
                    VStack(alignment: .leading) {
                        Text(adapter.name)
                        Text(probe.connected ? "подключён" : "запомнен")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if probe.running {
                        ProgressView()
                    }
                }
                Button("Подключиться") { connect(adapter) }
                    .disabled(probe.running)
                Button("Отключиться") { probe.stop() }
                    .disabled(!probe.connected)
                Button("Забыть", role: .destructive) {
                    probe.stop()
                    AdapterStore.forget()
                    self.adapter = nil
                }
                .disabled(probe.running)
            } else {
                Text("Не выбран — найди его ниже и нажми на строку")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var handshakeSection: some View {
        Section {
            if let failure = probe.failure {
                Label(failure, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
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
        } header: {
            Text("Рукопожатие")
        } footer: {
            if probe.connected, !probe.running, probe.failure == nil {
                Text("Адаптер отвечает. Транспорт готов для сессии ЭБУ.")
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section {
            Button(scanner.scanning ? "Остановить" : "Искать адаптер") {
                scanner.toggle()
            }
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

    // MARK: -

    /// Picking a device remembers it and goes straight into the handshake: a
    /// clone with no notify/write pair is only recognisable after connecting,
    /// so this is also how the unnamed neighbours get ruled out.
    private func choose(_ device: AdapterScanner.Found) {
        scanner.stop()
        let config = TransportConfig.ble(id: device.id, name: device.name)
        AdapterStore.save(config)
        adapter = config
        connect(config)
    }

    private func connect(_ config: TransportConfig) {
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
