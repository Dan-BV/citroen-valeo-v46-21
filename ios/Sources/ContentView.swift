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

/// The app around a session: the parameter list, the connect button, and the
/// status line the poll loop writes its cycle time into.
struct SessionScreen: View {
    let profile: Profile

    @StateObject private var session: ElmSession
    @State private var adapter: TransportConfig?
    @State private var settings = false
    @State private var mode: ElmSession.Mode = .obd

    /// Missing only if the build is broken, so the app carries on without the
    /// standard set rather than refusing to start.
    private let obd = try? ObdSet.bundled()

    init(profile: Profile) {
        self.profile = profile
        _session = StateObject(wrappedValue: ElmSession(
            profile: profile,
            obd: try? ObdSet.bundled(),
            makeTransport: { BleTransport(config: $0) }
        ))
        _adapter = State(initialValue: AdapterStore.load())
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Valeo V46.21")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            settings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        connectButton
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("Набор", selection: $mode) {
                            Text("OBD").tag(ElmSession.Mode.obd)
                            Text("V46.21").tag(ElmSession.Mode.proprietary)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .disabled(session.isBusy || obd == nil)
                    }
                }
                .safeAreaInset(edge: .bottom) { statusBar }
        }
        .sheet(isPresented: $settings) {
            AdapterSheet(session: session, profile: profile, adapter: $adapter)
        }
    }

    /// Which set is on screen follows the session while it runs, and the
    /// picker while it does not - so what is shown is always what is read.
    @ViewBuilder
    private var list: some View {
        if let obd, (session.isBusy ? session.mode : mode) == .obd {
            ObdList(session: session, obd: obd)
        } else {
            ParameterList(session: session, profile: profile)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if session.isBusy {
            Button("Стоп") { session.disconnect() }
        } else {
            Button("Пуск") {
                if let adapter {
                    session.connect(adapter, mode: mode)
                } else {
                    settings = true
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colour)
                .frame(width: 8, height: 8)
            Text(session.status)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            if session.logURL != nil {
                Image(systemName: "record.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text("\(session.loggedRows)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // What the cycle is actually paying for: the pages still in it.
            if session.mode == .proprietary {
                Text("\(session.polledPages.count) стр.")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var colour: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}
