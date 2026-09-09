import Foundation

/// Rewritten by .github/workflows/ios.yml so a build can be traced back to the
/// commit it came from. Stays "dev" for local builds.
enum BuildInfo {
    static let commit = "dev"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
