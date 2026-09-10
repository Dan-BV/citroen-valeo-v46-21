import Foundation

/// One session's recordings, seen the way their owner thinks of them: a drive,
/// not a pair of files.
///
/// A connect writes up to two CSVs - `fap_tech_` from the moment the adapter
/// opens and `fap_log_` once the ECU answers - so their name stamps sit
/// seconds apart. Files of different kinds that started within `pairWithin`
/// of each other are one drive; the start is the earliest stamp, the end the
/// latest write, and the two files travel together when shared.
struct Drive: Identifiable, Hashable {

    struct File: Hashable {
        let url: URL
        let started: Date
        let modified: Date
        let bytes: Int

        var isTech: Bool { url.lastPathComponent.hasPrefix(TechLog.prefix) }
    }

    let files: [File]

    var id: URL { files[0].url }
    var urls: [URL] { files.map(\.url) }
    var start: Date { files.map(\.started).min() ?? .distantPast }
    var end: Date { files.map(\.modified).max() ?? .distantPast }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var bytes: Int { files.reduce(0) { $0 + $1.bytes } }
    var hasLog: Bool { files.contains { !$0.isTech } }
    var hasTech: Bool { files.contains(where: \.isTech) }

    /// How far apart two files may start and still be one drive. The
    /// handshake between the two file opens takes seconds; a human retrying
    /// a failed connect takes longer than this.
    static let pairWithin: TimeInterval = 120

    /// Newest first.
    static func group(_ files: [File]) -> [Drive] {
        let sorted = files.sorted { $0.started < $1.started }
        var drives: [Drive] = []
        var i = 0
        while i < sorted.count {
            var members = [sorted[i]]
            var j = i + 1
            while j < sorted.count,
                  sorted[j].started.timeIntervalSince(members[0].started) <= pairWithin,
                  !members.contains(where: { $0.isTech == sorted[j].isTech }) {
                members.append(sorted[j])
                j += 1
            }
            drives.append(Drive(files: members))
            i = j
        }
        return drives.sorted { $0.start > $1.start }
    }

    /// Everything both recorders left on disk, as drives.
    static func onDisk(in directory: URL = CsvFile.documents) -> [Drive] {
        let urls = CsvLogger.logs(in: directory) + TechLog.logs(in: directory)
        return group(urls.map { url in
            let modified = CsvFile.modified(url)
            return File(url: url,
                        started: CsvFile.started(url) ?? modified,
                        modified: modified,
                        bytes: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        })
    }
}
