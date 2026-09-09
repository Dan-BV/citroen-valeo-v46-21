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
