import SwiftUI

struct ContentView: View {
    @State private var profile: Result<Profile, Error>?

    var body: some View {
        switch profile {
        case .none:
            ProgressView().task { profile = Result { try Profile.bundled() } }
        case let .failure(error):
            VStack(spacing: 8) {
                Image(systemName: "xmark.octagon").font(.largeTitle)
                Text(error.localizedDescription).multilineTextAlignment(.center)
            }
            .padding()
            .foregroundStyle(.red)
        case let .success(profile):
            SessionScreen(profile: profile)
        }
    }
}

/// The app around a session: the screen being read, the four toolbar buttons
/// and the strip under them that the poll loop writes its cycle time into.
///
/// Two kinds of screen sit under the same toolbar: the dashboards, swiped
/// between, and the full parameter list. The title names the one on show and
/// switches between them - the toolbar's right-hand side is full, and the name
/// of the dashboard being read is worth the space anyway.
///
/// Every button is an icon and all of them sit on the right, in two pairs:
/// what to read and what to read it with (filter, settings), then the session
/// itself (recording, start/stop). Start is the only filled one. The strip is
/// owned here rather than by the screens so that its two faces - status while
/// reading, the page-cost advice while choosing parameters - never stack.
struct SessionScreen: View {
    let profile: Profile

    /// Parameters by key, built once: a tile holds a key, not a field.
    private let index: FieldIndex

    @StateObject private var session: ElmSession
    @StateObject private var boards = DashboardStore()
    @State private var adapter: TransportConfig?
    @State private var settings = false
    @State private var logs = false
    @State private var editing = false

    /// Which dashboard is on show, and whether the list is up instead.
    @State private var boardID: UUID?
    @State private var showingList = false
    @State private var renaming = false
    @State private var name = ""

    init(profile: Profile) {
        self.profile = profile
        self.index = FieldIndex(profile)
        _session = StateObject(wrappedValue: ElmSession(
            profile: profile,
            makeAdapter: { config in
                switch config {
                case .ble:
                    return ElmAdapter(transport: BleTransport(config: config))
                case .thinkDiag:
                    // Read at connect time rather than once at launch: a
                    // script imported since is the one to use, and one just
                    // removed must not go on working from memory.
                    return ThinkDiagAdapter(transport: BleTransport(config: config),
                                            script: ThinkDiagScriptStore.current())
                }
            }
        ))
        _adapter = State(initialValue: AdapterStore.load())
    }

    var body: some View {
        NavigationStack {
            screen
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { titleMenu }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        filterButton
                        settingsButton
                        logsButton
                        connectButton
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { strip }
        }
        // The dashboards are the session's other reader, and this is the whole
        // of the wiring between them: a set of keys. The session merges it with
        // the list's selection, so a parameter both want is read once, kept
        // once and written to the log once.
        .onChange(of: boards.keys, initial: true) { _, keys in
            session.setDashboardKeys(keys)
        }
        .sheet(isPresented: $settings) {
            AdapterSheet(session: session, profile: profile, adapter: $adapter)
        }
        .sheet(isPresented: $logs) {
            NavigationStack {
                LogList(session: session)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Закрыть") { logs = false }
                        }
                    }
            }
        }
        .alert("Название дашборда", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Отмена", role: .cancel) {}
            Button("Готово") {
                if let board = currentBoard { boards.rename(board.id, to: name) }
            }
        }
    }

    // MARK: - what is on show

    @ViewBuilder
    private var screen: some View {
        if onList {
            ParameterList(session: session, profile: profile, editing: $editing)
        } else {
            DashboardPager(session: session,
                           store: boards,
                           profile: profile,
                           index: index,
                           boardID: $boardID,
                           editing: $editing)
        }
    }

    /// With every dashboard deleted there is nothing to swipe through, so the
    /// list is what there is.
    private var onList: Bool { showingList || boards.boards.isEmpty }

    private var currentBoard: Dashboard? {
        if let boardID, let board = boards.board(boardID) { return board }
        return boards.boards.first
    }

    private var title: String {
        onList ? "Параметры" : (currentBoard?.name ?? "Дашборд")
    }

    /// The title doubles as the switch between the screens and as the place
    /// dashboards are managed from: there is no room for a fifth button, and a
    /// menu under the name of the thing it acts on is where it would be looked
    /// for anyway.
    private var titleMenu: some View {
        Menu {
            Section {
                ForEach(boards.boards) { board in
                    Button {
                        show(board.id)
                    } label: {
                        check(board.name, !onList && currentBoard?.id == board.id)
                    }
                }
                Button {
                    showingList = true
                    editing = false
                } label: {
                    check("Все параметры", onList)
                }
            }
            Section {
                Button {
                    addBoard()
                } label: {
                    Label("Новый дашборд", systemImage: "plus")
                }
                if !onList, let board = currentBoard {
                    Button {
                        name = board.name
                        renaming = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                    Button {
                        if let copy = boards.duplicate(board.id) { show(copy) }
                    } label: {
                        Label("Дублировать", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        remove(board.id)
                    } label: {
                        Label("Удалить дашборд", systemImage: "trash")
                    }
                }
            }
            Section {
                // The one lever that actually shortens a cycle is asking for
                // fewer pages. This is it in a tap: read what the dashboards
                // show and nothing else.
                Button {
                    session.readOnlyDashboards()
                } label: {
                    Label("Читать только дашборды", systemImage: "bolt")
                }
                .disabled(boards.keys.isEmpty)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func check(_ title: String, _ on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func show(_ id: UUID) {
        boardID = id
        showingList = false
        editing = false
    }

    private func addBoard() {
        let board = Dashboard(name: "Дашборд \(boards.boards.count + 1)")
        boards.add(board)
        show(board.id)
        // Straight into edit mode: an empty board has nothing else to offer.
        editing = true
    }

    private func remove(_ id: UUID) {
        boards.remove(id)
        boardID = boards.boards.first?.id
        editing = false
    }

    // MARK: - toolbar

    /// Choosing what is read, or what a dashboard shows - whichever screen is
    /// up. Same glyph the Mail app uses for its filter, filled while the mode
    /// is on; a second tap is "done".
    private var filterButton: some View {
        Button {
            withAnimation { editing.toggle() }
        } label: {
            Image(systemName: editing
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(editing ? "Готово"
                            : onList ? "Выбор параметров" : "Правка плиток")
    }

    private var settingsButton: some View {
        Button {
            settings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Настройки")
    }

    /// One glyph, three states: grey outline when nothing would be recorded,
    /// orange outline when recording is armed but there is no session yet,
    /// red fill while a file is open. No row counter here on purpose - a
    /// number ticking in the toolbar is noise at the wheel.
    private var logsButton: some View {
        Button {
            session.flushLog()
            logs = true
        } label: {
            Image(systemName: recording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(recording ? Color.red : armed ? Color.orange : Color.secondary)
        }
        .accessibilityLabel(recording ? "Идёт запись, логи"
                            : armed ? "Запись включена, логи" : "Логи")
    }

    private var recording: Bool { session.logURL != nil || session.techURL != nil }
    private var armed: Bool { session.logToFile || session.techToFile }

    /// Start is the primary action and the only filled button. Stop keeps the
    /// place and changes colour, so the thumb does not have to hunt. With no
    /// adapter chosen the button is hollow and leads to the settings.
    @ViewBuilder
    private var connectButton: some View {
        if session.isBusy {
            Button {
                session.disconnect()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Стоп")
        } else if let adapter {
            Button {
                session.connect(adapter)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Пуск")
        } else {
            Button {
                settings = true
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .accessibilityLabel("Выбрать адаптер")
        }
    }

    // MARK: - strip

    @ViewBuilder
    private var strip: some View {
        Group {
            if editing {
                advice
            } else {
                statusLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colour)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 12)
            cycleTime
        }
    }

    /// Measured while connected; otherwise what a cycle *will* cost at the
    /// current selection, from the round trips this adapter showed before, so
    /// the effect of a change is visible without starting the car.
    @ViewBuilder
    private var cycleTime: some View {
        if session.isConnected, let ms = session.lastCycleMs {
            Text("\(ms.formatted()) мс")
                .font(.body.weight(.semibold).monospacedDigit())
        } else if !session.isBusy, let ms = session.predictedCycleMs {
            Text("~\(ms.formatted()) мс")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if adapter == nil, !session.isBusy { return "Адаптер не выбран" }
        return session.status
    }

    private var colour: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    /// The one thing worth saying out loud while choosing parameters: cycle
    /// time is paid per page, so the cheapest way to a fast screen is fewer
    /// pages - not fewer parameters. With two screens asking for pages it also
    /// has to say which of them the time is going on.
    private var advice: some View {
        let pages = session.polledPages
        let held = session.dashboardOnlyPages
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(pages.count) стр. в круге")
                    .font(.footnote.monospacedDigit())
                if !held.isEmpty {
                    Text("· \(held.count) из-за дашбордов")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let ms = session.predictedCycleMs {
                    Text("~\(ms.formatted()) мс")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Страница стоит один обмен независимо от того, сколько "
                 + "параметров из неё взято. Дешевле убрать страницу, чем "
                 + "параметры.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
