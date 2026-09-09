import Foundation

/// The standard OBD-II mode 01 set, bundled from the same `data/obd2/obd2.json`
/// that `tools/obd2/make_obd2.py` splices into index.html - so there is one
/// table, not one per version.
///
/// These readings need no calibration: the formulas are the standard's own. The
/// point of having them at all is speed. A page of the proprietary set answers
/// with 40-70 bytes, which BLE has to deliver in eight notifications; a mode-01
/// reply for six PIDs fits in two.
struct ObdSet: Decodable {

    struct Header: Decodable {
        let req: String
        let res: String
    }

    struct Param: Decodable, Identifiable {
        let key: String
        let label: String
        /// The whole request, e.g. `010C`.
        let pid: String
        let length: Int
        let scale: Double
        let delta: Double
        let unit: String
        let low: Double
        let high: Double
        let decimals: Int

        enum CodingKeys: String, CodingKey {
            case key = "k"
            case label = "l"
            case pid
            case length = "n"
            case scale = "z"
            case delta = "d"
            case unit = "u"
            case low = "lo"
            case high = "hi"
            case decimals = "dec"
        }

        var id: String { key }

        /// The PID without its mode, e.g. `0C`.
        var code: String { String(pid.dropFirst(2)).uppercased() }

        /// A mode-01 request is answered by mode + 0x40: `010C` -> `410C`.
        var marker: String {
            guard let mode = Int(pid.prefix(2), radix: 16) else { return pid }
            return String(format: "%02X", (mode + 0x40) & 0xFF) + code
        }

        func value(_ raw: Int) -> Double { Double(raw) * scale + delta }
    }

    let name: String
    let header: Header
    let params: [Param]

    var byKey: [String: Param] { Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0) }) }

    static func bundled(in bundle: Bundle = .main) throws -> ObdSet {
        guard let url = bundle.url(forResource: "obd2", withExtension: "json") else {
            throw LoadError.notBundled
        }
        return try JSONDecoder().decode(ObdSet.self, from: try Data(contentsOf: url))
    }

    enum LoadError: Error, LocalizedError {
        case notBundled

        var errorDescription: String? {
            switch self {
            case .notBundled: return "obd2.json отсутствует в сборке"
            }
        }
    }
}

/// Reading a mode-01 answer.
///
/// One request may carry several PIDs, and the answer then holds them one after
/// another: `41` followed by (pid, data...) for each. That is the whole reason
/// this exists - six values for one adapter turnaround instead of six.
enum ObdReply {

    /// The raw readings in `clean`, keyed by PID code (`0C`, `05`, ...).
    ///
    /// Returns `nil` when the walk does not land exactly on the end of the
    /// answer. That means a PID answered with a different number of bytes than
    /// the table expects, and every value after it would be read from the wrong
    /// place - so the caller must fall back to asking one PID at a time rather
    /// than trust it.
    static func walk(_ clean: String, expecting wanted: [ObdSet.Param]) -> [String: Int]? {
        let digits = Array(clean)
        guard digits.count >= 2, String(digits[0..<2]) == "41" else { return nil }

        let lengths = Dictionary(uniqueKeysWithValues: wanted.map { ($0.code, $0.length) })
        var out: [String: Int] = [:]
        var i = 2

        while i + 2 <= digits.count {
            let code = String(digits[i..<(i + 2)]).uppercased()
            guard let length = lengths[code] else { return nil }
            let from = i + 2
            let to = from + length * 2
            guard to <= digits.count, let raw = Int(String(digits[from..<to]), radix: 16) else {
                return nil
            }
            out[code] = raw
            i = to
        }

        // Trailing junk, or a PID the answer did not carry: not trustworthy.
        guard i == digits.count, out.count == wanted.count else { return nil }
        return out
    }

    /// Split a wanted set into requests. ISO 15765-4 allows up to six PIDs in
    /// one mode-01 request; whether the ECU honours it is another matter, which
    /// is what the fallback in the session is for.
    static func group(_ params: [ObdSet.Param], perRequest: Int = 6) -> [[ObdSet.Param]] {
        guard perRequest > 1 else { return params.map { [$0] } }
        return stride(from: 0, to: params.count, by: perRequest).map {
            Array(params[$0..<min($0 + perRequest, params.count)])
        }
    }

    /// `01` plus each PID's code: `010C0D0511`.
    static func request(for group: [ObdSet.Param]) -> String {
        "01" + group.map(\.code).joined()
    }
}
