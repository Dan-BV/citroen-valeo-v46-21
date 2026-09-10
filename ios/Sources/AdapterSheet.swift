import SwiftUI
import UniformTypeIdentifiers

/// Everything that is setup rather than reading: which adapter, the ECU
/// diagnostics that need a live link, and - folded away - what the profile
/// holds and which build this is.
///
/// Choosing an ELM327 clone checks it on the spot: the scan list folds, the AT
/// handshake runs, and the one line that matters lands under the adapter's
/// name - the chip's own banner, or why it did not answer. The exchange
/// itself is not shown; the session runs the same commands and the tech log
/// keeps every reply.
///
/// The ThinkDiag has no scan list and no AT handshake to run. There is one of
/// them and it is found by the name it advertises, so choosing the *type* is
/// the whole choice - and what needs saying instead is whether its activation
/// script is loaded, because without that it cannot open a session.
struct AdapterSheet: View {
    @ObservedObject var session: ElmSession
    let profile: Profile
    @Binding var adapter: TransportConfig?

    @StateObject private var scanner = AdapterScanner()
    @StateObject private var probe = ElmProbe()
    @Environment(\.dismiss) private var dismiss

    @State private var script: ThinkDiagScript?
    @State private var importing = false
    @State private var scriptProblem: String?

    private enum Kind: Hashable { case elm, thinkDiag }

    var body: some View {
        NavigationStack {
            List {
                typeSection
                adapterSection
                if kind == .elm {
                    scanSection
                } else {
                    activationSection
                }
                Section("Диагностика") {
                    NavigationLink {
                        FaultsScreen(session: session)
                    } label: {
                        needsLink("Ошибки")
                    }
                    NavigationLink {
                        IdentScreen(session: session)
                    } label: {
                        needsLink("Идентификация ЭБУ")
                    }
                }
                aboutSection
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        scanner.stop()
                        probe.stop()
                        dismiss()
                    }
                }
            }
            .task { script = ThinkDiagScriptStore.current() }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.json],
                          onCompletion: received)
        }
    }

    // MARK: - which kind

    private var kind: Kind {
        if case .thinkDiag = adapter { return .thinkDiag }
        return .elm
    }

    /// Derived rather than held in its own `@State`: the chosen adapter is the
    /// only truth about which kind is in use, and a second copy of that would
    /// be a second thing to keep in step.
    private var kindBinding: Binding<Kind> {
        Binding(get: { kind }, set: { switchTo($0) })
    }

    @ViewBuilder
    private var typeSection: some View {
        Section {
            Picker("Тип", selection: kindBinding) {
                Text("ELM327").tag(Kind.elm)
                Text("ThinkDiag").tag(Kind.thinkDiag)
            }
            .pickerStyle(.segmented)
            .disabled(session.isBusy)
        }
    }

    /// Changing type drops whatever was chosen. The two are found in different
    /// ways - one by a stored identifier, one by an advertised name - so there
    /// is nothing to carry across, and a stale choice of the other kind would
    /// only ever fail to connect.
    private func switchTo(_ wanted: Kind) {
        guard wanted != kind, !session.isBusy else { return }
        probe.stop()
        scanner.reset()
        switch wanted {
        case .thinkDiag:
            let config = TransportConfig.thinkDiag
            AdapterStore.save(config)
            adapter = config
        case .elm:
            AdapterStore.forget()
            adapter = nil
        }
    }

    // MARK: -

    @ViewBuilder
    private var adapterSection: some View {
        Section("Адаптер") {
            if let adapter {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adapter.name)
                        if kind == .elm {
                            verdictLine
                        } else {
                            thinkDiagLine
                        }
                    }
                    Spacer()
                    if kind == .elm {
                        // The check reruns on demand from right here; there is
                        // no separate button for it and no exchange to scroll
                        // to. Nothing to rerun for a ThinkDiag: `ElmProbe`
                        // asks in ELM327 text, which it does not answer.
                        Button {
                            Task { await probe.run(adapter) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(probe.running || session.isBusy)
                        .accessibilityLabel("Проверить адаптер")
                    }
                }
                if kind == .elm {
                    Button("Забыть", role: .destructive) {
                        session.disconnect()
                        probe.stop()
                        AdapterStore.forget()
                        self.adapter = nil
                    }
                    .disabled(session.isBusy)
                }
            } else {
                Text("Не выбран — найди его ниже и нажми на строку")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The handshake in one line. Green with the chip's banner is the only
    /// state that means "go"; everything else says what is wrong.
    @ViewBuilder
    private var verdictLine: some View {
        switch probe.verdict {
        case .unchecked:
            if session.isBusy {
                Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Не проверен")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Проверяю…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .elm(banner):
            Label(banner, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .other(reply):
            Label("Отвечает, но не как ELM327: \(reply)", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .silent:
            Label("Связь есть, на команды не отвечает", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case let .failed(reason):
            Label("Не достучался: \(reason)", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// What to say under a ThinkDiag's name. There is nothing to check by
    /// asking it - `ElmProbe` speaks ELM327 text - so the useful state is
    /// whether the thing it needs to open a session is loaded.
    @ViewBuilder
    private var thinkDiagLine: some View {
        if session.isBusy {
            Text(session.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if script != nil {
            Label("Готов, сценарий активации загружен", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Нужен сценарий активации", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// The licence and activation frames, which are not in the app and cannot
    /// be: they are this adapter's own credentials and the repository is
    /// public. So they are imported, and checked here rather than at the car -
    /// the licence step alone is 525 bytes, and a file wrong by one digit
    /// looks exactly like a file that is right.
    @ViewBuilder
    private var activationSection: some View {
        Section {
            if let script {
                VStack(alignment: .leading, spacing: 3) {
                    Text(script.summary)
                        .font(.callout)
                    Text("снят \(script.capturedAt)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Не импортирован")
                    .foregroundStyle(.secondary)
            }
            Button(script == nil ? "Импортировать сценарий…" : "Заменить сценарий…") {
                importing = true
            }
            .disabled(session.isBusy)
            if script != nil {
                Button("Удалить сценарий", role: .destructive) {
                    ThinkDiagScriptStore.remove()
                    script = ThinkDiagScriptStore.current()
                    scriptProblem = nil
                }
                .disabled(session.isBusy)
            }
            if let scriptProblem {
                Label(scriptProblem, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Активация")
        } footer: {
            Text("Файл thinkdiag_script.json — лицензия адаптера. "
                 + "Сделай его командой tools/thinkdiag/make_script.py и перенеси "
                 + "на телефон по кабелю: он остаётся только здесь и в резервную "
                 + "копию не попадает.")
        }
    }

    private func received(_ result: Result<URL, Error>) {
        scriptProblem = nil
        do {
            script = try ThinkDiagScriptStore.importFile(at: try result.get())
        } catch {
            scriptProblem = error.localizedDescription
            // A bad file replaces nothing, so say what is still loaded.
            script = ThinkDiagScriptStore.current()
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section {
            Button(scanner.scanning ? "Остановить поиск" : "Искать адаптер") {
                scanner.toggle()
            }
            .disabled(session.isBusy)
            if scanner.found.isEmpty {
                if scanner.scanning {
                    Text("Поиск…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(scanner.found) { device in
                    Button {
                        choose(device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.id.uuidString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            Text(scanner.status)
        }
    }

    /// Out of the way, not gone: the profile numbers are what to quote when a
    /// value looks wrong, and the build is what to quote after an update.
    @ViewBuilder
    private var aboutSection: some View {
        Section {
            DisclosureGroup {
                row("ЭБУ", "\(profile.ecu) · \(profile.platform)")
                row("CAN", "\(profile.can.req) → \(profile.can.res)")
                row("Страницы", "\(profile.pages.count)")
                row("Живые параметры", "\(profile.liveParamCount)")
                row("Поля идентификации", "\(profile.identFieldCount)")
                row("Коды неисправностей", "\(profile.dtc.count)")
            } label: {
                row("О программе", "\(BuildInfo.version) · \(BuildInfo.commit)")
            }
        }
    }

    private func needsLink(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !session.isConnected {
                Text("нужна связь")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ device: AdapterScanner.Found) {
        scanner.reset()
        let config = TransportConfig.ble(id: device.id, name: device.name)
        AdapterStore.save(config)
        adapter = config
        // Prove the choice right away. Not while a session holds the link:
        // two connections to one adapter would fight over it.
        guard !session.isBusy else { return }
        Task { await probe.run(config) }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
