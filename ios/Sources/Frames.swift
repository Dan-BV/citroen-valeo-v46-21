import Foundation

/// Turning ELM327 replies into numbers. This is a port of
/// android/app/src/main/java/com/fap/modern/core/Frames.kt; the two are held in
/// step by the parity fixture in data/parity/golden.json.
///
/// The multi-frame handling matters: for an ISO-TP answer the adapter prints a
/// length header line and then one line per frame prefixed with its index -
///
///     03B
///     0:61FF044F8F4F
///     1:50FFFFFF0000
///
/// Stripping every non-hex character would fold those `0`, `1`, `03B` digits
/// into the payload and silently corrupt every field after the first frame.
enum Frames {
    static func clean(_ raw: String) -> String {
        let lines = raw.split(omittingEmptySubsequences: false) { $0 == "\r" || $0 == "\n" }
        let multi = lines.contains { frameBody(trimmed($0)) != nil }
        var out = ""
        out.reserveCapacity(raw.count)
        for line in lines {
            let ln = trimmed(line)
            if ln.isEmpty || ln == ">" { continue }
            if let body = frameBody(ln) {
                out += hexOnly(body)
                continue
            }
            if multi, isLengthLine(ln) { continue }
            out += hexOnly(ln)
        }
        return out
    }

    /// `true` when the adapter answered with something other than data.
    static func isError(_ raw: String) -> Bool {
        let u = raw.uppercased()
        return u.contains("NO DATA") || u.contains("ERROR") || u.contains("UNABLE")
            || u.contains("STOPPED") || u.contains("BUFFER FULL") || u.contains("?")
    }

    /// Read a field out of an answer, MSB first. The database labels these
    /// little-endian but the wire is the other way round; live captures settle
    /// it (engine speed `04 4F` = 1103 rpm).
    static func extract(_ cleanHex: String, marker: String, offset: Int, length: Int) -> Int? {
        guard let digits = extractHex(cleanHex, marker: marker, offset: offset, length: length) else {
            return nil
        }
        return Int(digits, radix: 16)
    }

    /// Hex digits of a field, for identification values that are packed digits.
    static func extractHex(_ cleanHex: String, marker: String, offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, let at = cleanHex.range(of: marker) else { return nil }
        let markerStart = cleanHex.distance(from: cleanHex.startIndex, to: at.lowerBound)
        let start = markerStart + offset * 2
        let end = start + length * 2
        guard end <= cleanHex.count else { return nil }
        let lower = cleanHex.index(cleanHex.startIndex, offsetBy: start)
        let upper = cleanHex.index(cleanHex.startIndex, offsetBy: end)
        return String(cleanHex[lower..<upper])
    }

    // MARK: - fault records

    /// Split a fault-read answer into records, the way the scan profile says
    /// this module lays them out.
    ///
    /// CAN pads the last frame of an answer with zero bytes, and an all-zero
    /// record is padding rather than a fault - no ECU numbers a fault `$0000`.
    /// On a KWP module the count byte bounds the list as well, which is what
    /// keeps a truncated reply from being read past its end.
    static func dtcRecords(_ cleanHex: String, _ layout: ScanProfile.FaultFrames) -> [Dtc] {
        let digits = Array(cleanHex)
        guard layout.record > 0, digits.count >= layout.header * 2 else { return [] }
        var limit = Int.max
        if layout.hasCount {
            guard digits.count >= 4,
                  let count = Int(String(digits[2..<4]), radix: 16) else { return [] }
            limit = count
        }
        let body = digits[(layout.header * 2)...]
        var out: [Dtc] = []
        var at = body.startIndex
        while at + layout.record * 2 <= body.endIndex, out.count < limit {
            let record = Array(body[at..<(at + layout.record * 2)])
            at += layout.record * 2
            if record.allSatisfy({ $0 == "0" }) { continue }
            func field(_ offset: Int, _ length: Int) -> String {
                let from = offset * 2, to = from + length * 2
                guard from >= 0, to <= record.count else { return "" }
                return String(record[from..<to])
            }
            out.append(Dtc(code: field(layout.codeAt, layout.codeLength),
                           failureType: layout.failureTypeAt.map { field($0, 1) } ?? "",
                           status: field(layout.statusAt, 1)))
        }
        return out
    }

    /// The status byte of a UDS fault is the ISO 14229 bit field, and PSA asks
    /// for mask `09`: bit 0 says the test is failing right now and bit 3 that
    /// the fault has been confirmed over enough driving cycles. Those two carry
    /// the verdict; the rest colours it in.
    ///
    /// A KWP module answers a byte of its own with no published meaning, so
    /// this returns nil for one and the screen shows the raw byte.
    static func dtcStatusText(_ status: String, _ layout: ScanProfile.FaultFrames) -> String? {
        guard layout.statusIsStandard, let v = Int(status, radix: 16) else { return nil }
        let failing = v & 0x01 != 0, confirmed = v & 0x08 != 0, pending = v & 0x04 != 0
        var text: String
        if confirmed {
            text = failing ? "Постоянная — присутствует сейчас"
                           : "Записана в памяти, сейчас не проявляется"
        } else if failing {
            text = "Присутствует, ещё не подтверждена"
        } else {
            text = pending ? "Ожидает подтверждения" : "Не активна"
        }
        if v & 0x80 != 0 { text += " · горит сигнализатор" }
        return text
    }

    /// Whether the fault is failing at this moment, for the "present" mark.
    /// Only a UDS status says; a KWP one is left alone.
    static func dtcIsPresent(_ status: String, _ layout: ScanProfile.FaultFrames) -> Bool {
        guard layout.statusIsStandard, let v = Int(status, radix: 16) else { return false }
        return v & 0x01 != 0
    }

    /// A negative answer says why, and "why" is the difference between "this
    /// module cannot do it" and "try again with the ignition on".
    static let negativeResponses: [String: String] = [
        "11": "сервис не поддерживается",
        "12": "функция не поддерживается",
        "13": "неверная длина запроса",
        "22": "условия не выполнены (зажигание, обороты)",
        "31": "запрос вне допустимого диапазона",
        "33": "нужен доступ по безопасности",
        "78": "ЭБУ занят, ответ не пришёл вовремя",
        "7F": "сервис недоступен в этой сессии",
    ]

    /// Reads `7F <service> <code>` as a sentence, or nil if this is not one.
    static func negativeResponse(_ cleanHex: String) -> String? {
        let digits = Array(cleanHex)
        guard digits.count >= 6, String(digits[0..<2]) == "7F" else { return nil }
        let code = String(digits[4..<6])
        guard let meaning = negativeResponses[code] else {
            return "ЭБУ отказал (\(code))"
        }
        return "ЭБУ отказал (\(code): \(meaning))"
    }

    // MARK: -

    /// ELM waits out its whole timeout after a reply in case another ECU
    /// answers. Appending the expected response count makes it return as soon
    /// as the reply is assembled - the single biggest win in poll rate.
    static func withResponseCount(_ request: String, _ use: Bool) -> String {
        use ? request + "1" : request
    }

    // MARK: -

    private static func trimmed(_ s: Substring) -> String {
        String(s).trimmingCharacters(in: .whitespaces)
    }

    /// The bytes of `0:61FF04...` - a single hex digit, a colon, the payload.
    private static func frameBody(_ line: String) -> String? {
        var chars = Array(line)
        guard chars.count >= 2, isHex(chars[0]), chars[1] == ":" else { return nil }
        chars.removeFirst(2)
        return String(chars)
    }

    /// The `03B` line an ISO-TP answer starts with.
    private static func isLengthLine(_ line: String) -> Bool {
        (1...3).contains(line.count) && line.allSatisfy(isHex)
    }

    private static func hexOnly(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s where isHex(c) {
            out.append(upper(c))
        }
        return out
    }

    /// Deliberately ASCII-only, like the Kotlin original: Swift's
    /// `Character.isHexDigit` also matches fullwidth and other Unicode digits,
    /// which would let junk through into the payload.
    private static func isHex(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    private static func upper(_ c: Character) -> Character {
        ("a"..."f").contains(c)
            ? Character(UnicodeScalar(c.asciiValue! - 32))
            : c
    }
}
