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

/// The app around a session: the parameter list, the four toolbar buttons and
/// the strip under them that the poll loop writes its cycle time into.
///
/// Every button is an icon and all of them sit on the right, in two pairs:
/// what to read and what to read it with (filter, settings), then the session
/// itself (recording, start/stop). Start is the only filled one. The strip is
/// owned here rather than by the list so that its two faces - status while
/// reading, the page-cost advice while choosing parameters - never stack.
struct SessionScreen: View {
    let profile: Profile

    @StateObject private var session: ElmSession
    @State private var adapter: TransportConfig?
    @State private var settings = false
    @State private var logs = false
    @State private var editing = false

    init(profile: Profile) {
        self.profile = profile
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
                                            script: ThinkDiagScriptStore.current(),
                                            fastChannel: ThinkDiagFastChannel.isEnabled())
                }
            }
        ))
        _adapter = State(initialValue: AdapterStore.load())
    }

    var body: some View {
        NavigationStack {
            ParameterList(session: session, profile: profile, editing: $editing)
                .navigationTitle("Valeo V46.21")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        filterButton
                        settingsButton
                        logsButton
                        connectButton
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { strip }
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
    }

    // MARK: - toolbar

    /// Choosing which parameters are read. Same glyph the Mail app uses for
    /// its filter, filled while the mode is on; a second tap is "done".
    private var filterButton: some View {
        Button {
            withAnimation { editing.toggle() }
        } label: {
            Image(systemName: editing
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(editing ? "Готово" : "Выбор параметров")
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
    /// pages - not fewer parameters.
    private var advice: some View {
        let pages = session.polledPages
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(pages.count) стр. в круге")
                    .font(.footnote.monospacedDigit())
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
