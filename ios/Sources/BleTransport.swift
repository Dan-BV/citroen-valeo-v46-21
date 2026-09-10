import CoreBluetooth
import Foundation

/// ELM327 clones that expose a BLE GATT service instead of classic SPP
/// (Konnwei, Vgate and friends).
///
/// Port of android/app/src/main/java/com/fap/modern/core/BleTransport.kt. The
/// characteristic pair is discovered rather than hardcoded, for the same reason
/// as there: these clones use several different service UUIDs, and some
/// advertise one characteristic for both directions.
///
/// The handshake is driven by polling a locked state box rather than by parking
/// a continuation in every delegate callback. CoreBluetooth can deliver the
/// same callback twice, or none at all, and a continuation resumed twice is a
/// crash; at ELM327 speeds a 20 ms poll costs nothing.
final class BleTransport: NSObject, ElmTransport {

    private let wanted: UUID
    private let name: String
    private let queue = DispatchQueue(label: "com.fap.modern.ble")
    private let buffer = ByteBuffer()

    /// Everything the delegate callbacks touch.
    private final class Box {
        let lock = NSLock()
        var managerState: CBManagerState = .unknown
        var found: CBPeripheral?
        var connected = false
        var ready = false
        var failure: TransportError?
        /// Set by close(), so an expected disconnection is not a failure.
        var closing = false
        /// Characteristic discovery is per service, so the pick has to wait for
        /// the last one to answer.
        var servicesLeft = 0
        var notifyChar: CBCharacteristic?
        var writeChar: CBCharacteristic?
    }

    private let box = Box()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    init(config: TransportConfig) {
        switch config {
        case let .ble(id, name):
            self.wanted = id
            self.name = name
        }
        super.init()
    }

    // MARK: - ElmTransport

    func open() async throws {
        buffer.clear()
        mutate { $0.closing = false }
        let central = CBCentralManager(delegate: self, queue: queue)
        self.central = central

        try await settleBluetooth()

        let peripheral = try await find(central)
        self.peripheral = peripheral
        peripheral.delegate = self

        central.connect(peripheral, options: nil)
        try await wait(12, "подключение к \(name)") { self.snapshot { $0.connected } }

        peripheral.discoverServices(nil)
        try await wait(12, "поиск характеристик") { self.snapshot { $0.ready } }

        if let failure = snapshot({ $0.failure }) { throw failure }
        guard snapshot({ $0.writeChar }) != nil else { throw TransportError.noElmCharacteristics }
    }

    func write(_ data: Data) async throws {
        guard let peripheral, let characteristic = snapshot({ $0.writeChar }) else {
            throw TransportError.notOpen
        }
        if let failure = snapshot({ $0.failure }) { throw failure }

        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let limit = min(Chunker.bleChunk, peripheral.maximumWriteValueLength(for: type))

        let chunks = Chunker.chunks(data, size: max(limit, 1))
        for (index, chunk) in chunks.enumerated() {
            peripheral.writeValue(chunk, for: characteristic, type: type)
            // The clones drop data if chunks arrive back to back - but only
            // between chunks. Pausing after the last one delayed every single
            // exchange by 8 ms for nothing, and a command is one chunk.
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    func read(until terminator: Character, timeout: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let reply = buffer.take(upTo: terminator) { return reply }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            // Woken by the notification that carries the data rather than by a
            // timer. The 2 ms poll this replaces cost nothing but wakeups in
            // the foreground; held for the length of a drive in the background
            // it is a busy-wait, and that is what iOS terminates an app for.
            await buffer.waitForData(upTo: left)
        }
        return buffer.takeAll()
    }

    func drain() {
        buffer.clear()
    }

    var stats: LinkStats { buffer.stats }

    func close() {
        mutate { $0.closing = true }
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        central = nil
        peripheral = nil
        buffer.clear()
        mutate { box in
            box.connected = false
            box.ready = false
            box.notifyChar = nil
            box.writeChar = nil
            box.found = nil
            box.failure = nil
        }
    }

    // MARK: - the handshake

    /// CBCentralManager starts in `.unknown` and reports its real state through
    /// the delegate, so nothing can be asked of it until then.
    private func settleBluetooth() async throws {
        try await wait(12, "включение Bluetooth") {
            switch self.snapshot({ $0.managerState }) {
            case .unknown, .resetting: return false
            default: return true
            }
        }
        switch snapshot({ $0.managerState }) {
        case .poweredOn: return
        case .poweredOff: throw TransportError.bluetoothOff
        case .unauthorized: throw TransportError.unauthorized
        case .unsupported: throw TransportError.unsupported
        default: throw TransportError.timedOut("включение Bluetooth")
        }
    }

    /// The adapter is usually still in CoreBluetooth's cache from the scan that
    /// picked it, in which case no scan is needed at all.
    private func find(_ central: CBCentralManager) async throws -> CBPeripheral {
        if let known = central.retrievePeripherals(withIdentifiers: [wanted]).first {
            return known
        }
        central.scanForPeripherals(withServices: nil)
        defer { central.stopScan() }
        do {
            try await wait(12, "поиск \(name)") { self.snapshot { $0.found } != nil }
        } catch TransportError.timedOut {
            throw TransportError.notFound(name)
        }
        guard let found = snapshot({ $0.found }) else { throw TransportError.notFound(name) }
        return found
    }

    private func wait(_ seconds: TimeInterval, _ what: String,
                      until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let failure = snapshot({ $0.failure }) { throw failure }
            if done() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TransportError.timedOut(what)
    }

    private func snapshot<T>(_ get: (Box) -> T) -> T {
        box.lock.lock(); defer { box.lock.unlock() }
        return get(box)
    }

    private func mutate(_ change: (Box) -> Void) {
        box.lock.lock(); defer { box.lock.unlock() }
        change(box)
    }
}

// MARK: - CBCentralManagerDelegate

extension BleTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        mutate { $0.managerState = central.state }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == wanted else { return }
        mutate { $0.found = peripheral }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        mutate { $0.connected = true }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        mutate { $0.failure = .connectFailed(name) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        mutate { box in
            box.connected = false
            // close() sets `closing` first, so an expected teardown is not
            // reported as a failure.
            if box.failure == nil, !box.closing { box.failure = .disconnected }
            box.ready = true
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            mutate { box in
                box.failure = .noElmCharacteristics
                box.ready = true
            }
            return
        }
        mutate { $0.servicesLeft = services.count }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        var notifyToEnable: CBCharacteristic?

        mutate { box in
            for characteristic in service.characteristics ?? [] {
                let p = characteristic.properties
                let canNotify = p.contains(.notify) || p.contains(.indicate)
                let canWrite = p.contains(.write) || p.contains(.writeWithoutResponse)
                if canNotify, box.notifyChar == nil { box.notifyChar = characteristic }
                if canWrite, box.writeChar == nil { box.writeChar = characteristic }
            }
            box.servicesLeft -= 1

            let complete = box.notifyChar != nil && box.writeChar != nil
            if complete || box.servicesLeft <= 0 {
                if complete {
                    notifyToEnable = box.notifyChar
                } else {
                    box.failure = .noElmCharacteristics
                }
                box.ready = true
            }
        }

        if let notifyToEnable {
            // CoreBluetooth writes the CCCD itself, unlike the Android version.
            peripheral.setNotifyValue(true, for: notifyToEnable)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        buffer.append(data)
    }
}
