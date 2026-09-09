import SwiftUI

/// Skeleton screen. It proves the two things the iOS build has to prove before
/// the session logic is ported: the shared generated profile parses on iOS, and
/// CoreBluetooth can see the adapter.
struct ContentView: View {
    @StateObject private var scanner = AdapterScanner()
    @State private var profile: Result<Profile, Error>?

    var body: some View {
        NavigationStack {
            List {
                profileSection
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
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            Text(scanner.status)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
