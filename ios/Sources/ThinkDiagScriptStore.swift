import Foundation

/// Where the licence script lives on the phone, and how it gets there.
///
/// **Application Support, not Documents.** `UIFileSharingEnabled` exposes
/// Documents, which is how the drive logs get pulled off in the Files app -
/// and the adapter's licence has no business sitting in a folder that anything
/// able to read the app container can read. Application Support is in the same
/// container and is not exposed. The imported copy is also marked as excluded
/// from backup, so it does not travel to iCloud either.
///
/// Documents is still read as a fallback. Dropping the file there through
/// Apple Devices File Sharing is the shortest route from a Windows machine,
/// and there is no reason to break it.
enum ThinkDiagScriptStore {

    /// Set by tests, so they neither write into the app's own folders nor
    /// depend on a non-hosted test bundle having them.
    static var root: URL?

    /// The folder the imported copy lives in. iOS does not create this one for
    /// an app, so it is made on demand.
    static func directory() throws -> URL {
        if let root { return root }
        return try FileManager.default.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
    }

    /// Where to look, in order: the imported copy, then anything dropped into
    /// Documents through Apple Devices File Sharing.
    private static var places: [URL] {
        if let root { return [root] }
        return [try? directory(), CsvFile.documents].compactMap { $0 }
    }

    /// What is on the phone, or nothing. For the connect path, which has a
    /// clearer error of its own to raise when there is no script.
    static func current() -> ThinkDiagScript? {
        try? loaded()
    }

    /// The same, saying why when there is nothing.
    static func loaded() throws -> ThinkDiagScript {
        for place in places
        where FileManager.default.fileExists(atPath: ThinkDiagScript.url(in: place).path) {
            return try ThinkDiagScript.load(in: place)
        }
        throw ThinkDiagScriptError.missing
    }

    /// Take a file the user picked and keep it.
    ///
    /// It is parsed before anything is written. A file with one bad hex digit
    /// must not replace a working script, and finding out at the car - where
    /// the licence step is 525 bytes nobody can check by eye - is exactly what
    /// importing instead of file-dropping is meant to avoid.
    @discardableResult
    static func importFile(at url: URL) throws -> ThinkDiagScript {
        // A document picker hands back a URL outside the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ThinkDiagScriptError.unreadable(error.localizedDescription)
        }

        let script: ThinkDiagScript
        do {
            script = try JSONDecoder().decode(ThinkDiagScript.self, from: data)
        } catch {
            throw ThinkDiagScriptError.malformed(error.localizedDescription)
        }
        guard !script.steps.isEmpty else { throw ThinkDiagScriptError.empty }
        _ = try script.plan()

        var target = ThinkDiagScript.url(in: try directory())
        try data.write(to: target, options: .atomic)
        var exclude = URLResourceValues()
        exclude.isExcludedFromBackup = true
        try? target.setResourceValues(exclude)
        return script
    }

    /// Forget the imported copy. Does not touch a file dropped into Documents,
    /// which is not ours to delete.
    static func remove() {
        guard let directory = try? directory() else { return }
        try? FileManager.default.removeItem(at: ThinkDiagScript.url(in: directory))
    }
}

extension ThinkDiagScript {
    /// One line for the settings screen: enough to tell a script for the right
    /// application from one captured for something else.
    var summary: String {
        let bytes = steps.reduce(0) { $0 + $1.payload.count / 2 }
        return "\(application) · \(steps.count) шагов · \(bytes) Б"
    }
}
