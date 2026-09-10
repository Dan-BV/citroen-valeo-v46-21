import Foundation

// MARK: - hex

extension Data {
    /// Bytes from a hex string, whitespace ignored. `nil` for an odd number of
    /// digits or a non-hex character, because a script file that is wrong by
    /// one character must fail loudly rather than send something else.
    init?(hex: String) {
        let digits = Array(hex.unicodeScalars.filter { !$0.properties.isWhitespace })
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let high = Data.nibble(digits[i]), let low = Data.nibble(digits[i + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
            i += 2
        }
        self = out
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        default: return nil
        }
    }
}

// MARK: - one exchange

/// One exchange of the opening sequence: a frame to send, and what the adapter
/// said back to it when this was captured.
struct ThinkDiagStep: Equatable {

    /// What to call this step in a message a person reads. The whole point of
    /// the handshake being a list rather than a straight line of code is being
    /// able to say *which* step the adapter stopped answering at.
    var label: String

    var cmd: UInt8
    var payload: Data

    /// The reply payload seen in the capture, when it is short enough to be
    /// worth recording. A mismatch is logged, never fatal - see `judge`.
    var expecting: Data?

    /// Whether silence here ends the opening.
    ///
    /// Three of the six opening queries answer with a two-byte status we never
    /// read - `21/2a`, `25/05`, `21/11`. Whether the adapter needs them asked
    /// at all is not something the capture can say: the official app asked
    /// them, so we ask them. But stopping on one is the worse guess of the
    /// two, because carrying on either reaches the licence or fails there -
    /// and both outcomes say more than never having tried.
    ///
    /// The identity queries stay required: without them there is no way to
    /// tell this adapter from some other device that answers `55aa`, and the
    /// licence is not something to send into an unknown box. Everything from
    /// the script is required too.
    var required: Bool

    init(label: String, cmd: UInt8, payload: Data,
         expecting: Data? = nil, required: Bool = true) {
        self.label = label
        self.cmd = cmd
        self.payload = payload
        self.expecting = expecting
        self.required = required
    }

    func frame(seq: UInt8) -> ThinkDiagFrame {
        ThinkDiagFrame.request(seq: seq, cmd: cmd, payload: payload)
    }
}

/// What one step produced.
enum ThinkDiagStepResult: Equatable {

    /// The adapter answered, with the bytes the capture led us to expect - or
    /// with bytes we had no expectation about.
    case answered(Data)

    /// It answered, but not with the captured bytes. Not treated as failure:
    /// the expectations come from three sessions with one adapter, so an
    /// unexpected-but-present answer is far more likely to be a gap in what we
    /// know than a broken adapter. It goes in the log so it can be looked at.
    case unexpected(Data)

    /// Nothing came back, or what came back was not an answer to this step.
    /// This is the one that ends the handshake.
    case silent

    var payload: Data? {
        switch self {
        case let .answered(data), let .unexpected(data): return data
        case .silent: return nil
        }
    }

    var isFailure: Bool { self == .silent }
}

// MARK: - the plan

/// The sequence the official app performs before it addresses any module.
///
/// Split in two on purpose. The opening is six one-byte queries with nothing
/// secret in them, so it lives here. Everything after is the licence and the
/// activation exchange - kilobytes of the adapter's own credentials - which
/// must not be committed to a public repository, so it is loaded at runtime
/// from `ThinkDiagScript`. See `tools/thinkdiag/make_script.py`.
enum ThinkDiagHandshake {

    /// Queries 1 to 6, exactly as captured, including the duplicate `21/03`.
    ///
    /// The duplicate is deliberate. There is no reason to think the adapter
    /// needs asking twice, but the cost is one exchange once per connection
    /// and the cost of guessing wrong about a reverse-engineered handshake is
    /// a session that will not start. Faithful first; trim later, with
    /// evidence.
    ///
    /// `21/29` is not here: the CITROEN sessions do not send it, only the
    /// EOBD2 one does. The opening is per-application, and V46.21 is what we
    /// are building for.
    static let opening: [ThinkDiagStep] = [
        ThinkDiagStep(label: "идентификация", cmd: 0x21, payload: Data([0x03])),
        ThinkDiagStep(label: "идентификация (повтор)", cmd: 0x21, payload: Data([0x03])),
        ThinkDiagStep(label: "версии", cmd: 0x21, payload: Data([0x05])),
        ThinkDiagStep(label: "запрос 2a", cmd: 0x21, payload: Data([0x2a]),
                      expecting: Data([0x2a, 0x00]), required: false),
        ThinkDiagStep(label: "запрос 25/05", cmd: 0x25, payload: Data([0x05]),
                      expecting: Data([0x05, 0x00]), required: false),
        ThinkDiagStep(label: "запрос 11", cmd: 0x21, payload: Data([0x11]),
                      expecting: Data([0x11, 0x00]), required: false),
    ]

    /// Where in `opening` each identity reply lands, so a caller does not have
    /// to match on the label.
    static let identityStep = 0
    static let versionStep = 2

    /// The whole opening, in order. Without a script this is the six queries
    /// and nothing else - enough to identify the adapter and prove the link
    /// carries `55aa`, which is worth doing on its own even when the licence
    /// is not to hand.
    static func plan(with script: ThinkDiagScript?) throws -> [ThinkDiagStep] {
        guard let script else { return opening }
        return opening + (try script.plan())
    }

    /// What to make of a reply.
    ///
    /// `reply` is whatever came back, or `nil` for nothing. A frame that does
    /// not answer this request is the same as nothing: it is either a late
    /// reply to the previous step or a frame we do not understand, and in both
    /// cases carrying on would read it as this step's answer.
    static func judge(_ step: ThinkDiagStep,
                      request: ThinkDiagFrame,
                      reply: ThinkDiagFrame?) -> ThinkDiagStepResult {
        guard let reply, reply.answers(request) else { return .silent }
        if let expecting = step.expecting, reply.payload != expecting {
            return .unexpected(reply.payload)
        }
        return .answered(reply.payload)
    }
}

// MARK: - the part that stays local

/// The licence and activation exchange, replayed from a capture.
///
/// This file is **never committed**: it carries the adapter's licence blob and
/// its activation credentials. It is produced from a local capture by
/// `tools/thinkdiag/make_script.py` and dropped into the app's Documents
/// folder through the Files app, the same folder the drive logs come out of.
///
/// One of its steps is known not to be a replay. The 39-byte `27/01` request
/// after the activation challenge is 32 bytes of session-unique data in every
/// capture, and no run of the challenge appears in it, so it is either computed
/// with a key the official app holds or generated fresh. Replaying it may or
/// may not be accepted; that is the experiment W6 exists to run, and the reason
/// every step carries a label is so the app can say exactly where it stopped.
struct ThinkDiagScript: Codable, Equatable {

    struct Step: Codable, Equatable {
        var label: String
        /// Hex, one byte, e.g. `"21"`.
        var cmd: String
        /// Hex, the whole payload including its sub-command byte.
        var payload: String
        /// Hex, optional.
        var expecting: String?
    }

    /// Which diagnostic application the capture came from, e.g.
    /// `CITROEN V46.21`. Recorded because the licence blob is per-application:
    /// the EOBD2 session sends a different one.
    var application: String

    /// When it was captured, so a script older than the adapter's firmware can
    /// be spotted rather than puzzled over.
    var capturedAt: String

    var note: String?
    var steps: [Step]

    static let fileName = "thinkdiag_script.json"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func load(in directory: URL) throws -> ThinkDiagScript {
        let url = Self.url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThinkDiagScriptError.missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ThinkDiagScriptError.unreadable(error.localizedDescription)
        }
        let script: ThinkDiagScript
        do {
            script = try JSONDecoder().decode(ThinkDiagScript.self, from: data)
        } catch {
            throw ThinkDiagScriptError.malformed(error.localizedDescription)
        }
        guard !script.steps.isEmpty else { throw ThinkDiagScriptError.empty }
        // Fail here rather than mid-handshake: a bad digit in a 1627-byte
        // payload is worth finding before the adapter is holding a half-opened
        // session.
        _ = try script.plan()
        return script
    }

    func plan() throws -> [ThinkDiagStep] {
        try steps.map { step in
            guard let cmd = Data(hex: step.cmd), cmd.count == 1 else {
                throw ThinkDiagScriptError.badCommand(step.label)
            }
            guard let payload = Data(hex: step.payload), !payload.isEmpty else {
                throw ThinkDiagScriptError.badPayload(step.label)
            }
            var expecting: Data?
            if let text = step.expecting {
                guard let bytes = Data(hex: text) else {
                    throw ThinkDiagScriptError.badPayload(step.label)
                }
                expecting = bytes
            }
            return ThinkDiagStep(label: step.label, cmd: cmd[cmd.startIndex],
                                 payload: payload, expecting: expecting)
        }
    }
}

enum ThinkDiagScriptError: LocalizedError, Equatable {
    case missing
    case unreadable(String)
    case malformed(String)
    case empty
    case badCommand(String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "Нет файла \(ThinkDiagScript.fileName) в папке приложения"
        case let .unreadable(why):
            return "Не удалось прочитать \(ThinkDiagScript.fileName): \(why)"
        case let .malformed(why):
            return "Файл \(ThinkDiagScript.fileName) повреждён: \(why)"
        case .empty:
            return "В файле \(ThinkDiagScript.fileName) нет ни одного шага"
        case let .badCommand(label):
            return "Шаг «\(label)»: неверная команда"
        case let .badPayload(label):
            return "Шаг «\(label)»: неверные данные"
        }
    }
}
