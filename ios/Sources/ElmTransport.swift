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

/// What the link cost for one reply.
///
/// BLE hands data over in notification-sized pieces, and counting them is the
/// only way to tell two very different bottlenecks apart: a ceiling on the
/// notification size (many pieces, all the same small size, one per connection
/// event) versus a slow serial link inside the adapter (few pieces, arriving
/// slowly). The measurement matters because the answers differ - a different
/// adapter fixes one and not the other.
struct LinkStats: Equatable {
    var notifications = 0
    var bytes = 0
    /// The largest piece seen, i.e. the MTU the adapter actually uses.
    var largest = 0
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
    /// the answer to the next command. Also resets `stats`, which therefore
    /// always describes the reply to the command just sent.
    func drain()

    /// What the link cost for the reply since the last drain.
    var stats: LinkStats { get }

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
final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var link = LinkStats()

    /// A reader parked in `waitForData`, and a wakeup that arrived while none
    /// was parked.
    ///
    /// Reads used to wait by polling this buffer every 2 ms. In the foreground
    /// that only costs wakeups, but a background session polls for as long as
    /// the drive lasts, and a continuous busy-wait is what iOS terminates an
    /// app for. So the data itself ends the wait.
    ///
    /// This has to be the same lock that guards `text`: appending and waking
    /// are one step, or a reader can park just after the data it wanted arrived
    /// and then sit there until its timeout. And it has to survive being woken
    /// twice or never, because CoreBluetooth does both - hence a guarded slot
    /// and a flag rather than a bare continuation, resuming one of those twice
    /// being a crash.
    private var waiter: CheckedContinuation<Void, Never>?
    private var signalled = false

    /// What arrived since the last `clear()`.
    var stats: LinkStats {
        lock.lock(); defer { lock.unlock() }
        return link
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return text.isEmpty
    }

    func append(_ data: Data) {
        // ELM327 talks ASCII; anything else is line noise, and dropping it is
        // better than letting it derail the hex parsing downstream.
        let ascii = String(data: data, encoding: .ascii)
            ?? String(decoding: data, as: UTF8.self)
        var wake: CheckedContinuation<Void, Never>?
        lock.lock()
        text += ascii
        link.notifications += 1
        link.bytes += data.count
        link.largest = max(link.largest, data.count)
        if let parked = waiter {
            waiter = nil
            wake = parked
        } else {
            signalled = true
        }
        lock.unlock()
        // Outside the lock: resuming a continuation runs its task, and that
        // task's next move is to come straight back here for the data.
        wake?.resume()
    }

    /// Returns once `append` has been called, or after `timeout`, whichever
    /// comes first.
    ///
    /// An early return is allowed and harmless - the caller re-checks the
    /// buffer either way - which is what makes the flag above safe to keep at
    /// one slot.
    func waitForData(upTo timeout: TimeInterval) async {
        if takeSignal() { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.park() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
            // Whichever arm lost is still outstanding. The sleeper takes the
            // cancellation; a parked reader has to be let go by hand, or the
            // group would wait for it forever.
            self.release()
            await group.waitForAll()
        }
    }

    private func takeSignal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if signalled {
            signalled = false
            return true
        }
        return false
    }

    private func park() async {
        var stale: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signalled {
                signalled = false
                lock.unlock()
                continuation.resume()
                return
            }
            // There is one reader - the session serialises through an actor -
            // but if that ever stops being true, let the previous one go rather
            // than stranding it.
            stale = waiter
            waiter = continuation
            lock.unlock()
            stale?.resume()
        }
    }

    /// Lets a parked reader go without claiming that data arrived.
    private func release() {
        lock.lock()
        let parked = waiter
        waiter = nil
        lock.unlock()
        parked?.resume()
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
        link = LinkStats()
    }
}
