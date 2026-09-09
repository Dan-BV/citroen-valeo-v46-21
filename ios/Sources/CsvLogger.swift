import Foundation

/// Background CSV recorder: one column per parameter, one row per poll cycle.
///
/// Port of android/app/src/main/java/com/fap/modern/core/CsvLogger.kt, and the
/// format is deliberately identical - `time_ms,iso,<keys>`, Unix milliseconds,
/// `iso` in local time, an empty cell where a parameter had no valid reading.
/// `data/logs/README.md` describes that shape and the drive analysis in
/// `out/drives/` reads it, so a recording made on the phone has to drop into
/// the same table as the Android ones.
///
/// Files land in Documents, which is what `UIFileSharingEnabled` exposes: they
/// show up under the app's folder in Files, and a share sheet can send one
/// anywhere. A free signing certificate grants no iCloud container, so this is
/// the only route off the phone.
final class CsvLogger {

    static let prefix = "fap_log_"

    private let file: CsvFile
    private var keys: [String] = []

    var url: URL? { file.url }
    var rows: Int { file.rows }
    var isRunning: Bool { file.isOpen }

    init(directory: URL = CsvFile.documents) {
        file = CsvFile(directory: directory, prefix: Self.prefix)
    }

    static func logs(in directory: URL = CsvFile.documents) -> [URL] {
        CsvFile.files(in: directory, prefix: prefix)
    }

    func start(keys: [String]) throws {
        guard !isRunning, !keys.isEmpty else { return }
        self.keys = keys
        try file.open(header: "time_ms,iso," + keys.joined(separator: ","))
    }

    func log(_ at: Date, _ values: [String: Sample]) {
        guard isRunning else { return }
        var row = CsvTime.columns(at)
        for key in keys {
            row += ","
            if let sample = values[key], sample.valid {
                row += "\(sample.value)"
            }
        }
        file.append(row)
    }

    /// Push buffered rows to disk, so a file can be shared mid-session.
    func flush() {
        file.flush()
    }

    func stop() {
        file.close()
        keys = []
    }
}
