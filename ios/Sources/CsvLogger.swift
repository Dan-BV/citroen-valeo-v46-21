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

    private let directory: URL
    private let queue = DispatchQueue(label: "com.fap.modern.csv")

    private var handle: FileHandle?
    private var keys: [String] = []
    private var pending = Data()
    private var lastFlush = Date.distantPast

    private(set) var url: URL?
    private(set) var rows = 0

    /// Buffer a couple of seconds of cycles rather than touching the disk on
    /// every one, but not more - a session that ends in a crash should still
    /// have almost everything.
    private let flushEvery: TimeInterval = 2

    var isRunning: Bool { handle != nil }

    init(directory: URL = CsvLogger.documents) {
        self.directory = directory
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Every recording in the folder, newest first.
    static func logs(in directory: URL = CsvLogger.documents) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return all
            .filter { $0.pathExtension == "csv" && $0.lastPathComponent.hasPrefix("fap_log_") }
            .sorted { a, b in
                let ta = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let tb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return ta > tb
            }
    }

    // MARK: -

    func start(keys: [String]) throws {
        try queue.sync {
            guard handle == nil, !keys.isEmpty else { return }
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(
                "fap_log_\(Self.stamp.string(from: Date())).csv")
            // FileHandle(forWritingTo:) needs the file to exist already.
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: nil)

            let handle = try FileHandle(forWritingTo: file)
            self.handle = handle
            self.keys = keys
            self.url = file
            self.rows = 0
            self.pending = Data()
            write("time_ms,iso," + keys.joined(separator: ",") + "\n")
            flushLocked()
        }
    }

    func log(_ at: Date, _ values: [String: Sample]) {
        queue.sync {
            guard handle != nil else { return }
            var row = "\(Int64(at.timeIntervalSince1970 * 1000)),\(Self.iso.string(from: at))"
            for key in keys {
                row += ","
                if let sample = values[key], sample.valid {
                    row += "\(sample.value)"
                }
            }
            write(row + "\n")
            rows += 1
            if Date().timeIntervalSince(lastFlush) > flushEvery { flushLocked() }
        }
    }

    /// Push buffered rows to disk, so a file can be shared mid-session.
    func flush() {
        queue.sync { flushLocked() }
    }

    func stop() {
        queue.sync {
            flushLocked()
            try? handle?.close()
            handle = nil
            // A start with no rows leaves a header-only file; every connect
            // would otherwise litter the folder.
            if rows == 0, let url {
                try? FileManager.default.removeItem(at: url)
            }
            url = nil
            keys = []
        }
    }

    // MARK: - all of these run on `queue`

    private func write(_ text: String) {
        pending.append(Data(text.utf8))
    }

    private func flushLocked() {
        guard let handle, !pending.isEmpty else { return }
        try? handle.write(contentsOf: pending)
        pending = Data()
        lastFlush = Date()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()
}
