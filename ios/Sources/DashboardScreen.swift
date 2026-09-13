import SwiftUI
import UIKit

/// The dashboards, one per page, swiped between.
///
/// A page rather than a screen of its own so that the toolbar and the status
/// strip above stay put: the cycle time is the number watched while driving,
/// and it must not disappear because a dashboard is on screen instead of the
/// list.
struct DashboardPager: View {

    @ObservedObject var session: ElmSession
    @ObservedObject var store: DashboardStore
    let profile: Profile
    let index: FieldIndex

    @Binding var boardID: UUID?
    @Binding var editing: Bool

    var body: some View {
        TabView(selection: selection) {
            ForEach(store.boards) { board in
                DashboardScreen(session: session,
                                store: store,
                                profile: profile,
                                index: index,
                                board: board,
                                editing: $editing)
                    .tag(board.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: store.boards.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { boardID ?? store.boards.first?.id ?? UUID() },
            set: { boardID = $0 }
        )
    }
}

/// One dashboard: its tiles, laid out, and the edit mode that builds them.
struct DashboardScreen: View {

    @ObservedObject var session: ElmSession
    @ObservedObject var store: DashboardStore
    let profile: Profile
    let index: FieldIndex
    let board: Dashboard

    @Binding var editing: Bool

    @State private var picking = false
    @State private var editingTile: Tile?

    private let spacing: CGFloat = 10
    /// Narrower than this and a tile cannot hold a two-line label and a number,
    /// so the column count comes from the width rather than from the size class:
    /// a phone in landscape is not a phone in portrait with bigger tiles.
    private let minimumTile: CGFloat = 185

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let width = max(minimumTile, geometry.size.width - spacing * 2)
                let columns = max(2, Int(width / minimumTile))
                let unit = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(rows(columns)) { row in
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(row.tiles) { tile in
                                cell(tile, width: span(tile, columns: columns, unit: unit))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if editing { add }
                    if board.tiles.isEmpty, !editing { empty }
                }
                .padding(spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $picking) {
            TilePicker(session: session,
                       profile: profile,
                       existing: board.keys) { field in
                store.addTile(Tile(key: field.key), to: board.id)
            }
        }
        .sheet(item: $editingTile) { tile in
            editor(tile)
        }
    }

    // MARK: - layout

    /// A row of the grid. Tiles are packed left to right in the order the
    /// reader put them in, a wide one taking two columns; `LazyVGrid` cannot
    /// span columns, so the packing is done here where it is plain to read.
    private struct Row: Identifiable {
        let id: Int
        let tiles: [Tile]
    }

    private func rows(_ columns: Int) -> [Row] {
        var rows: [Row] = []
        var current: [Tile] = []
        var used = 0
        for tile in board.tiles {
            let want = min(tile.size.columns, columns)
            if used + want > columns {
                rows.append(Row(id: rows.count, tiles: current))
                current = []
                used = 0
            }
            current.append(tile)
            used += want
        }
        if !current.isEmpty { rows.append(Row(id: rows.count, tiles: current)) }
        return rows
    }

    private func span(_ tile: Tile, columns: Int, unit: CGFloat) -> CGFloat {
        let want = CGFloat(min(tile.size.columns, columns))
        return unit * want + spacing * (want - 1)
    }

    // MARK: - tiles

    @ViewBuilder
    private func cell(_ tile: Tile, width: CGFloat) -> some View {
        let field = index[tile.key]
        if editing {
            Button {
                if field == nil {
                    // Nothing to edit on a parameter this profile no longer
                    // carries; the only useful action is removing it.
                    store.removeTile(tile.id, from: board.id)
                } else {
                    editingTile = tile
                }
            } label: {
                face(tile, field, width: width)
            }
            .buttonStyle(.plain)
        } else if let field, field.kind == .numeric {
            NavigationLink {
                GraphScreen(session: session, field: Readout(field))
            } label: {
                face(tile, field, width: width)
            }
            .buttonStyle(.plain)
        } else {
            face(tile, field, width: width)
        }
    }

    @ViewBuilder
    private func face(_ tile: Tile, _ field: Profile.Field?, width: CGFloat) -> some View {
        Group {
            if let field {
                TileView(session: session, tile: tile, field: Readout(field))
            } else {
                missing(tile)
            }
        }
        .frame(width: width, height: tile.size.height)
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// A tile naming a parameter the profile no longer has. The profile is
    /// regenerated from the Diagbox databases now and then, and a silently
    /// blank tile would be worse than saying what happened.
    private func missing(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.key)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("нет в профиле")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var add: some View {
        Button {
            picking = true
        } label: {
            Label("Добавить параметр", systemImage: "plus")
                .font(.callout)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Пустой дашборд")
                .font(.headline)
            Text("Кнопка фильтра сверху — добавить плитки.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func editor(_ tile: Tile) -> some View {
        if let field = index[tile.key] {
            TileEditor(tile: tile,
                       field: Readout(field),
                       position: board.tiles.firstIndex(where: { $0.id == tile.id }) ?? 0,
                       count: board.tiles.count,
                       onChange: { store.update($0, in: board.id) },
                       onMove: { store.move(tile.id, by: $0, in: board.id) },
                       onDelete: { store.removeTile(tile.id, from: board.id) })
        }
    }
}
