import Foundation

/// Remembers which adapter was chosen.
///
/// Four unnamed devices with a strong signal sat next to the car during the
/// first scan, so picking by name is not an option. What is stored is the
/// CoreBluetooth peripheral identifier, which lets the next connection skip
/// scanning altogether - see `BleTransport.find`.
enum AdapterStore {
    private static let key = "adapter"

    static func load(_ defaults: UserDefaults = .standard) -> TransportConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TransportConfig.self, from: data)
    }

    static func save(_ config: TransportConfig, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }

    static func forget(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
