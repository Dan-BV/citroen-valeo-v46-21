import Foundation

/// One row per adapter exchange: what was asked, how much came back, in how
/// many BLE pieces, and how long it took.
///
/// This exists to answer a question the drive log cannot. Measured on the car,
/// four proprietary pages cost 600-700 ms per cycle while the small torque page
/// alone costs 20 ms - and the Android app over classic Bluetooth shows the
/// same 470-810 ms on the same pages, which rules the radio out as the main
/// cost. What is left is proportional to the size of the reply: the ELM327
/// prints ASCII hex, two characters per byte, over whatever serial link sits
/// between its chip and the radio module.
///
/// So the numbers to collect are time against reply length, and the size of the
/// pieces the link delivers:
///
///   * a straight line of about 1 ms per character means a slow serial link
///     inside the adapter - a different adapter would fix it;
///   * a large fixed cost per exchange regardless of length means the adapter's
///     firmware, and a faster link would buy little;
///   * many pieces all of the same small size means a notification-size ceiling.
///
/// The three have different answers, which is why this is measured rather than
/// assumed.
final class TechLog {

    static let prefix = "fap_tech_"

    struct Exchange {
        let at: Date
        let mode: String
        let command: String
        let replyChars: Int
        let stats: LinkStats
        let ms: Int
        let ok: Bool
        let note: String
    }

    private let file: CsvFile

    var url: URL? { file.url }
    var rows: Int { file.rows }
    var isRunning: Bool { file.isOpen }

    init(directory: URL = CsvFile.documents) {
        file = CsvFile(directory: directory, prefix: Self.prefix)
    }

    static func logs(in directory: URL = CsvFile.documents) -> [URL] {
        CsvFile.files(in: directory, prefix: prefix)
    }

    static let header = "time_ms,iso,mode,command,reply_chars,notifications," +
        "link_bytes,largest,ms,ok,note"

    func start() throws {
        guard !isRunning else { return }
        try file.open(header: Self.header)
    }

    func log(_ exchange: Exchange) {
        guard isRunning else { return }
        file.append([
            CsvTime.columns(exchange.at),
            exchange.mode,
            exchange.command,
            "\(exchange.replyChars)",
            "\(exchange.stats.notifications)",
            "\(exchange.stats.bytes)",
            "\(exchange.stats.largest)",
            "\(exchange.ms)",
            exchange.ok ? "1" : "0",
            exchange.note,
        ].joined(separator: ","))
    }

    func flush() {
        file.flush()
    }

    func stop() {
        file.close()
    }
}
