import Foundation

/// Which parameters the reader chose, kept between launches.
///
/// It was not kept before: every launch started from the built-in selection,
/// which was tolerable while the list was the only screen and became silly
/// once a dashboard - which is kept - sits next to it. Same storage and the
/// same injected `UserDefaults` as `PagePlan`, so a session's whole
/// arrangement (what is read, how often, and how it is shown) survives a
/// restart or nothing does.
final class SelectionStore {

    private let defaults: UserDefaults
    private let storeKey = "selectedParameters"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` when there is nothing usable stored, so the caller falls back to
    /// its own default.
    ///
    /// Keys the profile no longer carries are dropped - the profile is
    /// regenerated from the Diagbox databases now and then - and a stored
    /// selection that nothing survives is treated as absent. So is an empty
    /// one: an app that starts up reading nothing at all looks broken, and the
    /// reader can always clear the list again in one tap.
    func load(valid: Set<String>) -> Set<String>? {
        guard let stored = defaults.stringArray(forKey: storeKey) else { return nil }
        let keys = Set(stored).intersection(valid)
        return keys.isEmpty ? nil : keys
    }

    /// Sorted, so the stored value is diffable and stable between writes.
    func save(_ keys: Set<String>) {
        defaults.set(keys.sorted(), forKey: storeKey)
    }
}
