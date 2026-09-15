import Foundation

/// Which modules this particular car turned out to have.
///
/// The address map is the whole B7 platform, and a given car answers on a
/// fraction of it - the rest is paid for one adapter timeout at a time, which
/// is most of the minute a full sweep costs. A full sweep writes down what
/// answered; every sweep after it walks that list instead, which is seconds.
struct EcuInventory: Codable, Equatable {
    /// CAN request header -> the ECU that answered on it. The name matters as
    /// well as the address: several candidates share an address and only one
    /// of them is fitted, so a later sweep can ask that one alone.
    var present: [String: String]
    var scannedAt: Date
    /// How many addresses the sweep that produced this had to walk, so the
    /// screen can say what the shortcut is worth.
    var walked: Int

    var count: Int { present.count }
}

/// Same storage and the same injected `UserDefaults` as `PagePlan` and
/// `SelectionStore`: a handful of values that must survive a restart, with no
/// reason for a database.
final class EcuInventoryStore {

    private let defaults: UserDefaults
    /// Versioned, because the first build wrote a map from any sweep at all -
    /// including one where the adapter could reach a single module - and a car
    /// whose map says "one block" would never ask for the others again. A map
    /// written by that build is not worth keeping.
    private let storeKey = "ecuInventory.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` when nothing usable is stored. An empty map counts as nothing: a
    /// sweep that found no module at all says something about the ignition or
    /// the adapter, not about the car, and must not become the list every
    /// later sweep trusts.
    func load() -> EcuInventory? {
        guard let data = defaults.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode(EcuInventory.self, from: data),
              !stored.present.isEmpty else { return nil }
        return stored
    }

    func save(_ inventory: EcuInventory) {
        guard !inventory.present.isEmpty,
              let data = try? JSONEncoder().encode(inventory) else { return }
        defaults.set(data, forKey: storeKey)
    }

    func forget() {
        defaults.removeObject(forKey: storeKey)
    }
}
