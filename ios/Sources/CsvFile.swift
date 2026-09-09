import Foundation

/// A CSV being appended to, and the bookkeeping both recorders need.
///
/// Writes are buffered for a couple of seconds rather than hitting the disk
/// every cycle, there is an on-demand flush so a file can be shared mid-drive,
/// and a file that never got a row is deleted on close - otherwise every
/// connect litters the folder.
final class CsvFile {

    private let directory: URL
    private let prefix: String
    private let queue: DispatchQueue
    private let flushEvery: TimeInterval = 2

    private var handle: FileHandle?
    private var pending = Data()
    private var lastFlush = Date.distantPast

    private(set) var url: URL?
    private(set) var rows = 0

    var isOpen: Bool { queue.sync { handle != nil } }

    init(directory: URL, prefix: String) {
        self.directory = directory
        self.prefix = prefix
        self.queue = DispatchQueue(label: "com.fap.modern.csv." + prefix)
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Every file this prefix has produced, newest first.
    static func files(in directory: URL, prefix: String) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return all
            .filter { $0.pathExtension == "csv" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { a, b in modified(a) > modified(b) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    // MARK: -

    func open(header: String) throws {
        try queue.sync {
            guard handle == nil else { return }
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(
                prefix + Self.stamp.string(from: Date()) + ".csv")
            // FileHandle(forWritingTo:) needs the file to exist already.
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: nil)

            handle = try FileHandle(forWritingTo: file)
            url = file
            rows = 0
            pending = Data()
            pending.append(Data((header + "\n").utf8))
            flushLocked()
        }
    }

    func append(_ line: String) {
        queue.sync {
            guard handle != nil else { return }
            pending.append(Data((line + "\n").utf8))
            rows += 1
            if Date().timeIntervalSince(lastFlush) > flushEvery { flushLocked() }
        }
    }

    func flush() {
        queue.sync { flushLocked() }
    }

    func close() {
        queue.sync {
            flushLocked()
            try? handle?.close()
            handle = nil
            if rows == 0, let url {
                try? FileManager.default.removeItem(at: url)
            }
            url = nil
        }
    }

    // MARK: - on `queue`

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
}

/// Timestamps as both recorders write them: Unix milliseconds and local ISO,
/// the format `data/logs/README.md` documents.
enum CsvTime {
    static func columns(_ at: Date) -> String {
        "\(Int64(at.timeIntervalSince1970 * 1000)),\(iso.string(from: at))"
    }

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()
}
