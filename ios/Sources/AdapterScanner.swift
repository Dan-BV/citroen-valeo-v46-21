import CoreBluetooth
import Foundation

/// Bare CoreBluetooth scan. This exists to answer one question before any
/// session logic is written: does an iPhone see the ELM327 clone at all, and
/// under what name. ELM327 BLE clones advertise several different service
/// UUIDs, so nothing is filtered here.
@MainActor
final class AdapterScanner: NSObject, ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var scanning = false
    @Published private(set) var status = "Bluetooth не запущен"

    private var central: CBCentralManager?

    func toggle() {
        scanning ? stop() : start()
    }

    func start() {
        found.removeAll()
        scanning = true
        if central == nil {
            // Creating the manager triggers the permission prompt.
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        beginScanIfReady()
    }

    func stop() {
        central?.stopScan()
        scanning = false
    }

    /// Stop and forget what was found, so the list folds away once a device
    /// has been chosen.
    func reset() {
        stop()
        found.removeAll()
    }

    private func beginScanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        status = "поиск"
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "готов"
        case .poweredOff: return "Bluetooth выключен"
        case .unauthorized: return "нет разрешения"
        case .unsupported: return "BLE не поддерживается"
        case .resetting: return "перезапуск"
        case .unknown: return "состояние неизвестно"
        @unknown default: return "состояние неизвестно"
        }
    }
}

extension AdapterScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            status = describe(central.state)
            if central.state == .poweredOn, scanning {
                beginScanIfReady()
            } else if central.state != .poweredOn {
                scanning = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? "(без имени)"
        let id = peripheral.identifier
        let rssi = RSSI.intValue

        Task { @MainActor in
            if let i = found.firstIndex(where: { $0.id == id }) {
                found[i].rssi = rssi
            } else {
                found.append(Found(id: id, name: name, rssi: rssi))
            }
            found.sort { $0.rssi > $1.rssi }
        }
    }
}
