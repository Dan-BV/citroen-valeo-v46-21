import Foundation

/// Length-prefixed strings, the shape every descriptive reply uses.
///
/// A `61/03` or `61/05` payload is the sub-command byte followed by a run of
///
///     len(2) | bytes, NUL-terminated inside that length
///
/// So `000a 56312e30302e30303000` is `V1.00.000`. The NUL is inside the count,
/// which is the detail worth having a decoder for: taking the length as the
/// string length leaves a NUL on the end of every value, and it only shows up
/// when one is compared or displayed.
enum ThinkDiagStrings {

    /// The strings in a reply payload, with the sub-command byte already
    /// dropped. `nil` if a length runs off the end - a truncated reply must not
    /// decode as a short list, because that is indistinguishable from an
    /// adapter that answered with fewer fields.
    static func decode(_ body: Data) -> [String]? {
        var out: [String] = []
        var rest = body
        while !rest.isEmpty {
            guard rest.count >= 2 else { return nil }
            let length = Int(rest[rest.startIndex]) << 8 | Int(rest[rest.index(after: rest.startIndex)])
            let from = rest.index(rest.startIndex, offsetBy: 2)
            guard let to = rest.index(from, offsetBy: length, limitedBy: rest.endIndex) else {
                return nil
            }
            var bytes = rest[from..<to]
            while bytes.last == 0 { bytes = bytes.dropLast() }
            out.append(String(decoding: bytes, as: UTF8.self))
            rest = rest[to...]
        }
        return out
    }
}

/// What the adapter says about itself, from the two queries the official app
/// opens with.
///
/// Kept positional on purpose. The adapter labels none of these - the names
/// below are what each position carried in the 2026-09-10 capture - so a
/// reply with a field more or less still decodes, and reads as blank rather
/// than as the wrong value shifted along.
struct ThinkDiagIdentity: Equatable {

    /// The five strings of a `61/03` reply, in wire order.
    var identity: [String] = []

    /// The four strings of a `61/05` reply.
    var versions: [String] = []

    /// 24 hex characters, and the only field long enough to be a device key.
    var hardwareId: String { at(identity, 0) }

    /// `979865497037` on this adapter - **not** the `9TFD20257708` printed on
    /// the case, which is what it advertises over BLE and what a `27/01`
    /// `016020` reply returns in ASCII. Two different numbers; connecting uses
    /// the advertised one.
    var serial: String { at(identity, 1) }

    /// `V1.00.000`.
    var firmware: String { at(identity, 2) }

    /// `20260130`, as eight digits.
    var built: String { at(identity, 3) }

    /// `13`.
    var revision: String { at(identity, 4) }

    /// `V1.23.004`.
    var software: String { at(versions, 0) }

    /// `V23.05`.
    var bootloader: String { at(versions, 1) }

    /// `V10.04`.
    var protocolVersion: String { at(versions, 2) }

    /// `diagmini`.
    var model: String { at(versions, 3) }

    /// The one check worth making before trusting any of the rest: that this
    /// is the kind of adapter the captured script was taken from. An adapter
    /// answering `55aa` with some other model would take the licence frames
    /// and do something we have never observed.
    var isDiagMini: Bool { model == "diagmini" }

    /// For the technical log, where the point is being able to tell later
    /// which adapter and which firmware produced a drive.
    var summary: String {
        let parts = [model, software, firmware, serial].filter { !$0.isEmpty }
        return parts.isEmpty ? "неизвестный адаптер" : parts.joined(separator: " · ")
    }

    /// Read a `61/03` payload, sub-command byte included.
    mutating func readIdentity(_ payload: Data) -> Bool {
        guard let strings = Self.strings(of: payload, sub: 0x03) else { return false }
        identity = strings
        return true
    }

    /// Read a `61/05` payload, sub-command byte included.
    mutating func readVersions(_ payload: Data) -> Bool {
        guard let strings = Self.strings(of: payload, sub: 0x05) else { return false }
        versions = strings
        return true
    }

    private static func strings(of payload: Data, sub: UInt8) -> [String]? {
        guard payload.first == sub else { return nil }
        return ThinkDiagStrings.decode(payload.dropFirst())
    }

    private func at(_ list: [String], _ i: Int) -> String {
        i < list.count ? list[i] : ""
    }
}
