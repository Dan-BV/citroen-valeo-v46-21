import Foundation

/// The handles this adapter knows modules by, and the frame that opens one.
///
/// A handle is not a CAN identifier and cannot be derived from one: no CAN
/// identifier crosses this wire at all, the identifiers living inside the
/// vehicle software the adapter downloaded. So a handle can only be observed -
/// and the capture of the official app's system scan observed thirty-four of
/// them, one per module it walked, each opened with the very same frame the
/// engine's channel is opened with.
///
/// Which handle is which module the capture does not say. That is what
/// `ElmSession.probeLinks` settles on the car: open each in turn, ask the
/// recognition frames the scan profile knows, and see which answers.
enum ThinkDiagLink {

    /// Opening a channel: `01 60 18 0c` then the nested frame
    ///
    ///     55 aa | 08 | 61 01 03 | link(2) | 30 <bs> <stmin> | checksum
    ///              └ nested length          └ ISO-TP flow control
    ///
    /// The checksum is an XOR over the nested frame from its length byte up to
    /// but excluding itself - which reproduces, byte for byte, all 68 channel
    /// opens in the captures. `ThinkDiagLinkTests` pins it against the one the
    /// replay script carries for the engine.
    static func openChannel(_ link: UInt16, stMin: UInt8 = ThinkDiagFastChannel.fastStMin) -> Data {
        let nested: [UInt8] = [0x08, 0x61, 0x01, 0x03,
                               UInt8(link >> 8), UInt8(link & 0xff),
                               0x30, 0x00, stMin]
        var out: [UInt8] = [0x01, 0x60, 0x18, 0x0c, 0x55, 0xaa]
        out += nested
        out.append(nested.reduce(0, ^))
        return Data(out)
    }

    /// Every handle the official app opened a channel to, in the order it
    /// walked them - which is its own system scan, so this is the list of
    /// modules it believes this car has.
    ///
    /// Two are known: `2905` is the engine and `2a25` the BSI, both settled by
    /// the requests they carried. The rest carried a session open, a `22F0xx`
    /// identification and a fault read, which is exactly what a system scan
    /// looks like and tells us nothing about which module each one is.
    ///
    /// Tied to one car and one downloaded vehicle software. A different car
    /// would hand out different handles, which is why this is observed data in
    /// a file and not a formula.
    static let known: [UInt16] = [
        0x2905, 0x2a25, 0x3e5d, 0x1f7f, 0x1bb3, 0x4743, 0x1f0a, 0x196a,
        0x1e4f, 0x4839, 0x2d0a, 0x45b8, 0x1d48, 0x2546, 0x3b8f, 0x2ebb,
        0x134a, 0x2f1d, 0x4f6a, 0x34fe, 0x39b9, 0x2da8, 0x35f6, 0x2d42,
        0x17ff, 0x247b, 0x1bc6, 0x1d3f, 0x1dfe, 0x4fca, 0x3d59, 0x2ea0,
        0x1277, 0x10ce,
    ]

    /// How a handle is written where an ELM327 would take a CAN header, so one
    /// `Adapter` API serves both: `#2905`.
    static let headerPrefix = "#"

    static func header(for link: UInt16) -> String {
        headerPrefix + String(format: "%04X", link)
    }

    /// The handle a header names, or nil when it names a CAN identifier.
    static func link(inHeader header: String) -> UInt16? {
        guard header.hasPrefix(headerPrefix) else { return nil }
        return UInt16(header.dropFirst(headerPrefix.count), radix: 16)
    }
}
