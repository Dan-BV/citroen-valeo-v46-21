import Foundation

/// One tile on a dashboard: a parameter, and how it is drawn.
///
/// A tile names a parameter by key and nothing else. It carries no reading of
/// its own and never asks the ECU for anything: the value it shows comes from
/// `ElmSession.values`, the same dictionary the parameter list reads. That is
/// what makes a parameter on three tiles and in the list one read, one column
/// and one cell in memory rather than three of each.
struct Tile: Identifiable, Hashable, Codable {

    enum Style: String, Codable, CaseIterable, Identifiable {
        case number
        case gauge
        case bar
        case graph

        var id: String { rawValue }

        var title: String {
            switch self {
            case .number: return "Число"
            case .gauge: return "Шкала"
            case .bar: return "Полоса"
            case .graph: return "График"
            }
        }
    }

    enum Size: String, Codable, CaseIterable, Identifiable {
        case small
        case wide
        case tall

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: return "Малая"
            case .wide: return "Широкая"
            case .tall: return "Высокая"
            }
        }

        /// How many grid columns the tile takes.
        var columns: Int { self == .small ? 1 : 2 }

        var height: CGFloat { self == .tall ? 190 : 108 }
    }

    var id: UUID
    var key: String
    var style: Style
    var size: Size
    /// Ends of the scale a gauge or a bar is drawn against, when the profile's
    /// own are useless: `REGIME_MOTEUR` runs 0…65535 there because that is the
    /// range of two raw bytes, and a needle against it would never leave the
    /// first degree. `nil` means "take the profile's".
    var low: Double?
    var high: Double?

    init(key: String,
         style: Style = .number,
         size: Size = .small,
         low: Double? = nil,
         high: Double? = nil,
         id: UUID = UUID()) {
        self.id = id
        self.key = key
        self.style = style
        self.size = size
        self.low = low
        self.high = high
    }

    enum CodingKeys: String, CodingKey {
        case id, key, style, size, low, high
    }

    /// Hand-written so that a layout saved by an older build survives a new
    /// one: a missing field or a style this version does not know falls back
    /// instead of throwing, and a throw here would lose every dashboard the
    /// reader has built.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decode(String.self, forKey: .key)
        let style = try container.decodeIfPresent(String.self, forKey: .style) ?? ""
        let size = try container.decodeIfPresent(String.self, forKey: .size) ?? ""
        self.style = Style(rawValue: style) ?? .number
        self.size = Size(rawValue: size) ?? .small
        low = try container.decodeIfPresent(Double.self, forKey: .low)
        high = try container.decodeIfPresent(Double.self, forKey: .high)
    }
}

/// A named set of tiles. Several may exist; the reader swipes between them.
struct Dashboard: Identifiable, Hashable, Codable {

    var id: UUID
    var name: String
    var tiles: [Tile]

    /// What this board needs read, without duplicates - the same parameter on
    /// two tiles is one key.
    var keys: Set<String> { Set(tiles.map(\.key)) }

    init(name: String, tiles: [Tile] = [], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.tiles = tiles
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Дашборд"
        tiles = try container.decodeIfPresent([Tile].self, forKey: .tiles) ?? []
    }
}

/// Parameters by key, so a tile can find the field it names without walking
/// the profile on every redraw.
///
/// A tile holds a key, not a field: the profile is regenerated from the
/// Diagbox databases now and then, and a key it no longer carries has to show
/// as missing rather than crash or silently vanish.
struct FieldIndex {

    private let fields: [String: Profile.Field]
    private let pages: [String: Profile.Page]

    init(_ profile: Profile) {
        var fields: [String: Profile.Field] = [:]
        var pages: [String: Profile.Page] = [:]
        for page in profile.pages {
            for field in page.params {
                fields[field.key] = field
                pages[field.key] = page
            }
        }
        self.fields = fields
        self.pages = pages
    }

    subscript(key: String) -> Profile.Field? { fields[key] }

    func page(of key: String) -> Profile.Page? { pages[key] }
}
