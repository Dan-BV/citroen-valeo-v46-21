import Foundation

/// How the adapter is reached.
///
/// One case only, unlike the Android version: on iOS an ELM327 clone has to
/// speak BLE. Classic Bluetooth SPP needs MFi hardware, and the K-line and
/// USB-serial paths of the web version have no iOS equivalent either.
enum TransportConfig: Equatable, Codable {
    /// `id` is CoreBluetooth's per-app peripheral identifier - deliberately not
    /// a MAC address like `TransportConfig.Ble.address` on Android. iOS never
    /// hands out the MAC, and this identifier is a different value in every
    /// app, so it is only ever meaningful to us.
    case ble(id: UUID, name: String)

    var name: String {
        switch self {
        case let .ble(_, name): return name
        }
    }
}

/// A raw byte pipe to an ELM327 adapter. Command framing lives in ElmSession.
protocol ElmTransport: AnyObject {
    func open() async throws
    func write(_ data: Data) async throws

    /// Everything received before `terminator`, which is consumed and left out
    /// - or whatever had arrived when `timeout` ran out. An ELM327 ends every
    /// reply with the `>` prompt, which is what makes a read finish early.
    func read(until terminator: Character, timeout: TimeInterval) async -> String

    /// Throw away whatever is still buffered, so a reply cannot be mistaken for
    /// the answer to the next command.
    func drain()

    func close()
}

extension ElmTransport {
    func write(_ text: String) async throws {
        try await write(Data(text.utf8))
    }
}

enum TransportError: LocalizedError, Equatable {
    case bluetoothOff
    case unauthorized
    case unsupported
    case notFound(String)
    case connectFailed(String)
    case noElmCharacteristics
    case disconnected
    case notOpen
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothOff:
            return "Bluetooth выключен"
        case .unauthorized:
            return "Нет разрешения на Bluetooth"
        case .unsupported:
            return "Устройство не поддерживает BLE"
        case let .notFound(name):
            return "Адаптер \(name) не найден"
        case let .connectFailed(name):
            return "Не удалось подключиться к \(name)"
        case .noElmCharacteristics:
            return "Устройство не похоже на ELM327: нет пары notify/write"
        case .disconnected:
            return "Соединение разорвано"
        case .notOpen:
            return "Транспорт не открыт"
        case let .timedOut(what):
            return "Таймаут: \(what)"
        }
    }
}

/// Splitting a command for BLE writes.
enum Chunker {
    /// Conservative payload per write: the default 23-byte MTU minus ATT
    /// overhead. The clones drop data if larger writes - or writes with no
    /// pause between them - are thrown at them.
    static let bleChunk = 20

    static func chunks(_ data: Data, size: Int) -> [Data] {
        guard size > 0, !data.isEmpty else { return data.isEmpty ? [] : [data] }
        var out: [Data] = []
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[i..<j])
            i = j
        }
        return out
    }
}

/// Bytes arriving from the adapter, and the wait for a whole reply.
///
/// BLE hands data over in notification-sized pieces with no framing of its own,
/// so a reply is accumulated here until the ELM327 prompt shows up. This is the
/// counterpart of the queue behind `InputStream` in the Kotlin transport, and
/// it is a separate type so it can be tested without any hardware.
final class ByteBuffer {
    private let lock = NSLock()
    private var text = ""

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return text.isEmpty
    }

    func append(_ data: Data) {
        // ELM327 talks ASCII; anything else is line noise, and dropping it is
        // better than letting it derail the hex parsing downstream.
        let ascii = String(data: data, encoding: .ascii)
            ?? String(decoding: data, as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        text += ascii
    }

    /// Everything before the first `terminator`, which is consumed but not
    /// returned; `nil` while it has not arrived yet.
    func take(upTo terminator: Character) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let at = text.firstIndex(of: terminator) else { return nil }
        let reply = String(text[..<at])
        text = String(text[text.index(after: at)...])
        return reply
    }

    func takeAll() -> String {
        lock.lock(); defer { lock.unlock() }
        let all = text
        text = ""
        return all
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        text = ""
    }
}
