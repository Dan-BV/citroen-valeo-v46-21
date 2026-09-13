import Combine
import Foundation

/// The dashboards, and the only place they are kept.
///
/// `UserDefaults` for the same reason `PagePlan` uses it: this is a handful of
/// kilobytes of the reader's own arrangement, it has to survive a restart, and
/// a free signing certificate grants no iCloud container to put it anywhere
/// better. The `UserDefaults` is injected so the tests get their own suite.
///
/// The store knows nothing about the session or the profile. It hands out a
/// set of keys; what that costs in cycle time is the session's business, and
/// whether a key still exists is the screen's.
final class DashboardStore: ObservableObject {

    @Published private(set) var boards: [Dashboard]

    private let defaults: UserDefaults
    private let storeKey = "dashboards"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([Dashboard].self, from: data) {
            // Including an empty array: a reader who deleted every board meant
            // it, and must not find the shipped one back at the next launch.
            boards = saved
        } else {
            boards = Self.seed
        }
    }

    /// Everything the dashboards need read, deduplicated. The same parameter on
    /// two boards is one key here, which is what keeps it one column in the
    /// recording and one read on the wire.
    var keys: Set<String> {
        boards.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
    }

    func board(_ id: UUID) -> Dashboard? { boards.first { $0.id == id } }

    // MARK: - boards

    @discardableResult
    func add(_ board: Dashboard) -> UUID {
        boards.append(board)
        save()
        return board.id
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        change(id) { $0.name = name }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return nil }
        let source = boards[index]
        // New identity for the copy and for every tile in it, or the two boards
        // share ids and SwiftUI cannot tell their rows apart.
        let copy = Dashboard(name: source.name + " (копия)",
                             tiles: source.tiles.map {
                                 Tile(key: $0.key, style: $0.style, size: $0.size,
                                      low: $0.low, high: $0.high)
                             })
        boards.insert(copy, at: index + 1)
        save()
        return copy.id
    }

    func remove(_ id: UUID) {
        boards.removeAll { $0.id == id }
        save()
    }

    // MARK: - tiles

    func addTile(_ tile: Tile, to id: UUID) {
        change(id) { $0.tiles.append(tile) }
    }

    func update(_ tile: Tile, in id: UUID) {
        change(id) { board in
            guard let at = board.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
            board.tiles[at] = tile
        }
    }

    func removeTile(_ tile: UUID, from id: UUID) {
        change(id) { $0.tiles.removeAll { $0.id == tile } }
    }

    /// Reordering one step at a time, because dragging a tile around a grid is
    /// fiddly at a kerbside and a pair of arrows is not.
    func move(_ tile: UUID, by offset: Int, in id: UUID) {
        change(id) { board in
            guard let at = board.tiles.firstIndex(where: { $0.id == tile }) else { return }
            let to = at + offset
            guard to >= 0, to < board.tiles.count else { return }
            board.tiles.swapAt(at, to)
        }
    }

    // MARK: -

    private func change(_ id: UUID, _ edit: (inout Dashboard) -> Void) {
        guard let at = boards.firstIndex(where: { $0.id == id }) else { return }
        edit(&boards[at])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        defaults.set(data, forKey: storeKey)
    }

    // MARK: - what ships

    /// One board, so the feature is not an empty screen at first launch.
    ///
    /// Every parameter on it comes from $C0, $C1, $C2, $C4 or $CA - pages the
    /// default selection already reads - so the shipped dashboard costs nothing
    /// on top of what the app polls anyway. The scale ends are set by hand
    /// where the profile's are the raw byte range rather than anything a needle
    /// could be drawn against.
    static var seed: [Dashboard] {
        [Dashboard(name: "Двигатель", tiles: [
            Tile(key: "REGIME_MOTEUR", style: .gauge, size: .small, low: 0, high: 6000),
            Tile(key: "VITESSE_VEHICULE", style: .number, size: .small),
            Tile(key: "TEMPERATURE_D_EAU_MOTEUR_d", style: .bar, size: .small, low: 40, high: 120),
            Tile(key: "TEMP_AIR_ADMISSION_SUP", style: .number, size: .small),
            Tile(key: "REMPLISSAGE_MESURE", style: .bar, size: .small, low: 0, high: 100),
            Tile(key: "COUPLE_VOLONTE_CONDUCTEUR", style: .number, size: .small),
            Tile(key: "AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE", style: .graph, size: .wide),
            Tile(key: "TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR",
                 style: .number, size: .small, low: 11, high: 15),
        ])]
    }
}
