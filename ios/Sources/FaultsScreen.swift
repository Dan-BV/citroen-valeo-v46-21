import SwiftUI

/// Fault memory of the whole car, one node per module.
///
/// The sweep walks the 41 diagnostic addresses of the platform, and every
/// module that answers becomes a node with its own fault list underneath. Three
/// ways to clear, because three are useful: the whole car at once, one module,
/// or a single fault opened from the list.
///
/// Reading holds the same lock as the poll loop, so live values freeze for the
/// minute it takes - which is why the screen says so, and why modules appear as
/// they answer instead of all at the end.
@MainActor
final class FaultTreeModel: ObservableObject {

    /// One per app rather than one per screen. The sweep costs a minute of
    /// frozen live values; walking out of the screen and back in must not
    /// spend it again, and a `@StateObject` would - the destination of a
    /// `NavigationLink` is built afresh every time it is pushed.
    static let shared = FaultTreeModel()

    @Published private(set) var nodes: [EcuNode] = []
    @Published private(set) var summary = ScanSummary()
    @Published private(set) var catalogue = FaultCatalogue(dictionary: nil,
                                                           engineName: "",
                                                           engineRequest: "")
    /// What the sweep is doing right now; nil when it is not running.
    @Published private(set) var progress: String?
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var swept = false
    @Published var onlyFaulty = false
    @Published private var expanded: Set<String> = []

    /// Which modules this car was found to have. Present from the first full
    /// sweep onwards, and what every later sweep walks instead of the platform.
    @Published private(set) var inventory: EcuInventory?

    private var scan: ScanProfile?
    /// Why the address map is missing, if it is. Without it there is nothing
    /// to walk, and that is worth saying plainly.
    private(set) var scanFailure: String?
    private let inventoryStore: EcuInventoryStore

    init(inventoryStore: EcuInventoryStore = EcuInventoryStore()) {
        self.inventoryStore = inventoryStore
        inventory = inventoryStore.load()
        do {
            scan = try ScanProfile.bundled()
        } catch {
            scanFailure = error.localizedDescription
        }
    }

    /// The engine's identity comes from the session, so the catalogue can name
    /// the one module whose identity is not in doubt.
    func attach(_ session: ElmSession) {
        guard catalogue.engineName.isEmpty else { return }
        catalogue = FaultCatalogue(dictionary: catalogue.dictionary,
                                   engineName: session.engineName,
                                   engineRequest: session.engineRequest)
    }

    var visibleNodes: [EcuNode] {
        onlyFaulty ? nodes.filter { !$0.faults.isEmpty } : nodes
    }

    var faultCount: Int { nodes.reduce(0) { $0 + $1.faults.count } }
    var faultyCount: Int { nodes.filter { !$0.faults.isEmpty }.count }
    var canClearEverything: Bool { nodes.contains { $0.clearable } }
    /// How many addresses a full sweep has to walk, for the button that offers
    /// one. Zero only if the address map did not load.
    var platformAddresses: Int { scan?.byAddress.count ?? 0 }

    func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.expanded.contains(id) ?? false },
                set: { [weak self] open in
                    if open { self?.expanded.insert(id) } else { self?.expanded.remove(id) }
                })
    }

    // MARK: -

    /// `full` walks the whole platform; otherwise the car's own modules, if a
    /// full sweep has already said which those are.
    func sweep(_ session: ElmSession, full: Bool = false) async {
        guard !busy else { return }
        guard let scan else {
            failure = scanFailure
            return
        }
        let fitted = full ? nil : inventory?.present
        busy = true
        failure = nil
        nodes = []
        summary = ScanSummary()
        progress = "Подготовка…"
        await loadDictionary()
        do {
            summary = try await session.scanFaults(
                scan,
                fitted: fitted,
                onProbe: { [weak self] i, total, address in
                    self?.progress = "Опрос \(i) из \(total) — адрес \(address)"
                },
                onModule: { [weak self] node in
                    guard let self else { return }
                    // A module with something to say opens itself; the rest
                    // stay shut so the list stays readable at a glance.
                    if !node.faults.isEmpty || node.failure != nil {
                        self.expanded.insert(node.id)
                    }
                    self.nodes.append(node)
                })
            swept = true
            // Only a sweep that could actually reach the whole platform may
            // write the map. A ThinkDiag reaches one module, so a map written
            // from its sweep would say this car has one module - and every
            // later sweep, on any adapter, would believe it.
            if summary.mapsTheCar { rememberInventory(walked: scan.byAddress.count) }
        } catch {
            failure = error.localizedDescription
        }
        progress = nil
        busy = false
    }

    /// Only a full sweep writes the map: a short one walks the map itself, so
    /// letting it rewrite the map would let one module that failed to answer
    /// erase itself for good.
    private func rememberInventory(walked: Int) {
        let present = Dictionary(nodes.map { ($0.target.request, $0.target.name) },
                                 uniquingKeysWith: { first, _ in first })
        guard !present.isEmpty else { return }
        let found = EcuInventory(present: present, scannedAt: Date(), walked: walked)
        inventoryStore.save(found)
        inventory = found
    }

    /// Back to walking the whole platform next time - for a car that has
    /// gained or lost a module, or a map taken with the ignition off.
    func forgetInventory() {
        inventoryStore.forget()
        inventory = nil
    }

    /// The sweep as a page of text, for reading away from the car or sending
    /// on. The technical log has every exchange of it, which is the wrong
    /// grain for "what does this car have".
    func report() -> String {
        var lines: [String] = []
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("Опрос блоков, \(stamp.string(from: Date()))")
        lines.append(summary.full
            ? "Полный обход платформы"
            : "Обход по сохранённой карте машины")
        lines.append("")
        for node in nodes {
            let head = "\(catalogue.title(of: node.target)) [\(node.target.family)] "
                + "\(node.target.request)/\(node.target.response) "
                + catalogue.names(of: node.target).joined(separator: " / ")
            lines.append(head)
            if !node.identHex.isEmpty { lines.append("    ид.: \(node.identHex)") }
            if let failure = node.failure {
                lines.append("    чтение ошибок: \(failure)")
            } else if !node.readable {
                lines.append("    чтение ошибок не описано")
            } else if node.faults.isEmpty {
                lines.append("    ошибок нет")
            } else {
                for fault in node.faults {
                    let detail = catalogue.detail(fault, of: node.target)
                    var line = "    \(fault.display)  "
                        + (detail.description ?? "нет описания в базе Diagbox")
                    if let failureText = detail.failureText { line += " · \(failureText)" }
                    line += " · " + (detail.statusText ?? "байт статуса \(fault.status)")
                    lines.append(line)
                }
            }
        }
        if !summary.unreachableFamilies.isEmpty {
            lines.append("")
            lines.append("Адаптер не умеет обращаться к: "
                         + summary.unreachableFamilies.joined(separator: ", "))
        }
        if !summary.silentFamilies.isEmpty {
            lines.append("")
            lines.append("Не ответили: " + summary.silentFamilies.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    func reread(_ node: EcuNode, session: ElmSession) async {
        guard let i = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        do {
            nodes[i].faults = try await session.faults(of: node.target)
            nodes[i].failure = nil
        } catch {
            nodes[i].failure = error.localizedDescription
        }
    }

    func rereadAlone(_ node: EcuNode, session: ElmSession) async {
        guard !busy else { return }
        busy = true
        await reread(node, session: session)
        busy = false
    }

    func clearModule(_ node: EcuNode, session: ElmSession) async {
        guard !busy else { return }
        busy = true
        failure = nil
        do {
            try await session.clearFaults(of: node.target)
        } catch {
            failure = error.localizedDescription
        }
        // Read back rather than assume: a fault whose cause is still there
        // comes straight back, and that is the thing worth seeing.
        await reread(node, session: session)
        busy = false
    }

    func clear(_ dtc: Dtc, of node: EcuNode, session: ElmSession) async {
        guard !busy else { return }
        busy = true
        failure = nil
        do {
            try await session.clear(dtc, of: node.target)
        } catch {
            failure = error.localizedDescription
        }
        await reread(node, session: session)
        busy = false
    }

    func clearEverything(_ session: ElmSession) async {
        let targets = nodes.filter(\.clearable)
        guard !busy, !targets.isEmpty else { return }
        busy = true
        failure = nil
        var refused: [String] = []
        for (i, node) in targets.enumerated() {
            progress = "Стирание \(i + 1) из \(targets.count) — "
                + catalogue.title(of: node.target)
            do {
                try await session.clearFaults(of: node.target)
            } catch {
                refused.append(catalogue.title(of: node.target))
            }
            await reread(node, session: session)
        }
        progress = nil
        busy = false
        if !refused.isEmpty {
            failure = "Не стёрлось: " + refused.joined(separator: ", ")
        }
    }

    /// 0.7 MB of descriptions, read once and off the main thread. A failure
    /// here costs the wording and nothing else - the codes still read, clear
    /// and show - so it is not reported as an error.
    private func loadDictionary() async {
        guard catalogue.dictionary == nil else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            try? DtcDictionary.bundled()
        }.value
        catalogue.dictionary = loaded
    }
}

struct FaultsScreen: View {
    @ObservedObject var session: ElmSession
    @ObservedObject private var model = FaultTreeModel.shared

    @State private var confirmingClearAll = false
    @State private var confirmingForget = false

    var body: some View {
        List {
            if !session.isConnected {
                Section {
                    Label("Нет связи с ЭБУ — нажми «Пуск» на главном экране",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }

            if let progress = model.progress {
                Section {
                    ProgressView(progress)
                } footer: {
                    Text("Пока идёт опрос, живые значения замирают: адаптер один, "
                         + "и очередь к нему общая с опросом.")
                }
            }

            ForEach(model.visibleNodes) { node in
                Section { moduleNode(node) }
            }

            if model.swept { tailSection }
            actionsSection
        }
        .navigationTitle("Ошибки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $model.onlyFaulty) {
                    Label("Только с ошибками",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .disabled(model.nodes.isEmpty)
            }
        }
        .task {
            model.attach(session)
            if !model.swept, !model.busy, session.isConnected {
                await model.sweep(session)
            }
        }
        .confirmationDialog("Забыть карту машины?",
                            isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Забыть", role: .destructive) { model.forgetInventory() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Следующий опрос снова пройдёт по всем адресам платформы и "
                 + "займёт около минуты, зато найдёт блок, которого раньше не было.")
        }
        .confirmationDialog("Стереть ошибки во всех блоках?",
                            isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("Стереть", role: .destructive) {
                Task { await model.clearEverything(session) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Коды и стоп-кадры будут потеряны безвозвратно. Если "
                 + "неисправность не устранена, она появится снова не сразу.")
        }
    }

    // MARK: -

    @ViewBuilder
    private func moduleNode(_ node: EcuNode) -> some View {
        DisclosureGroup(isExpanded: model.expansion(node.id)) {
            if let failure = node.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !node.readable {
                Text("Diagbox не описывает чтение ошибок для этого блока.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if node.faults.isEmpty {
                Label("Ошибок нет", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                ForEach(node.faults) { fault in
                    NavigationLink {
                        FaultDetailScreen(session: session, model: model,
                                          node: node, dtc: fault)
                    } label: {
                        faultRow(model.catalogue.detail(fault, of: node.target))
                    }
                }
            }

            if !node.identHex.isEmpty {
                LabeledContent("ид.", value: node.identHex)
                    .font(.caption.monospaced())
            }
            Button("Перечитать") {
                Task { await model.rereadAlone(node, session: session) }
            }
            .disabled(model.busy || !node.readable || !session.isConnected)
            if node.target.clear != nil {
                Button("Стереть в блоке", role: .destructive) {
                    Task { await model.clearModule(node, session: session) }
                }
                .disabled(model.busy || node.faults.isEmpty || !session.isConnected)
            }
        } label: {
            moduleHeader(node)
        }
    }

    private func moduleHeader(_ node: EcuNode) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.catalogue.title(of: node.target))
                    .font(.callout.bold())
                Text(model.catalogue.subtitle(of: node.target))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            badge(node)
        }
    }

    @ViewBuilder
    private func badge(_ node: EcuNode) -> some View {
        if node.failure != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if !node.readable {
            Text("—").foregroundStyle(.secondary)
        } else if node.faults.isEmpty {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text("\(node.faults.count)")
                .font(.callout.bold())
                .foregroundStyle(.red)
        }
    }

    private func faultRow(_ detail: FaultDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(detail.dtc.display)
                    .font(.callout.monospaced().bold())
                if detail.present {
                    Text("сейчас")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Text(detail.description ?? "нет описания в базе Diagbox")
                .font(.callout)
                .foregroundStyle(detail.description == nil ? .secondary : .primary)
            if let failureText = detail.failureText {
                Text(failureText).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail.statusText ?? "байт статуса \(detail.dtc.status)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryText: String {
        guard !model.nodes.isEmpty else { return "Ни один блок не ответил." }
        let blocks = plural(model.nodes.count, "блок", "блока", "блоков")
        let faults = plural(model.faultCount, "ошибка", "ошибки", "ошибок")
        return "Отвечают \(model.nodes.count) \(blocks), с ошибками "
            + "\(model.faultyCount), всего \(model.faultCount) \(faults)."
    }

    @ViewBuilder
    private var tailSection: some View {
        Section {
            Text(summaryText)
                .font(.callout)
            if !model.summary.unreachableFamilies.isEmpty {
                Text(adapterLimitNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.summary.silentFamilies.isEmpty {
                Text((model.summary.full ? "Не ответили: " : "Из карты не ответили: ")
                     + model.summary.silentFamilies.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ShareLink(item: model.report()) {
                Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
            }
            if let inventory = model.inventory {
                Button("Забыть карту машины") { confirmingForget = true }
                    .disabled(model.busy)
                Text(mapNote(inventory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if model.catalogue.dictionary == nil {
                Text("Словарь описаний не загрузился — коды показаны без расшифровки.")
            }
        }
    }

    /// A ThinkDiag reaches one module, so this is 40 families out of 41 - a
    /// wall of names that says nothing. The number and the way out say more.
    private var adapterLimitNote: String {
        let blocked = model.summary.unreachable.count
        let names = model.summary.unreachableFamilies
        let reachable = model.nodes.map { model.catalogue.title(of: $0.target) }
        var text = "Этот адаптер обращается только к "
            + (reachable.isEmpty ? "части блоков" : reachable.joined(separator: ", "))
            + ": остальные \(blocked) "
            + plural(blocked, "адрес", "адреса", "адресов")
            + " платформы ему недоступны, поэтому карта машины не сохранена."
        if blocked <= 6 {
            text += " Недоступны: " + names.joined(separator: ", ") + "."
        }
        text += " Чтобы опросить всю машину, нужен ELM327-совместимый адаптер"
            + " — у ThinkDiag нет способа назвать блок, которого нет в его"
            + " собственной таблице."
        return text
    }

    private func mapNote(_ inventory: EcuInventory) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "d MMMM, HH:mm"
        stamp.locale = Locale(identifier: "ru_RU")
        let blocks = plural(inventory.count, "блок", "блока", "блоков")
        return "Карта машины: \(inventory.count) \(blocks) из \(inventory.walked) "
            + "адресов, снята \(stamp.string(from: inventory.scannedAt))."
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if let inventory = model.inventory {
                Button("Опросить свои блоки (\(inventory.count))") {
                    Task { await model.sweep(session) }
                }
                .disabled(model.busy || !session.isConnected)
            }
            Button(model.inventory == nil
                   ? "Опросить блоки"
                   : "Полный обход (\(model.platformAddresses) адресов)") {
                Task { await model.sweep(session, full: true) }
            }
            .disabled(model.busy || !session.isConnected)
            Button("Стереть все ошибки", role: .destructive) { confirmingClearAll = true }
                .disabled(model.busy || !model.canClearEverything || !session.isConnected)
        } footer: {
            Text(model.inventory == nil
                 ? "Опрос идёт по всем диагностическим адресам платформы и занимает "
                   + "около минуты: за каждый адрес, на котором никого нет, адаптер "
                   + "платит таймаутом. Что ответило, запомнится — дальше можно "
                   + "опрашивать только свои блоки."
                 : "Карта машины снята полным обходом; опрос по ней идёт секунды. "
                   + "Полный нужен, если в машине что-то появилось или пропало.")
        }
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        switch (n % 100 / 10, n % 10) {
        case (1, _): return many
        case (_, 1): return one
        case (_, 2), (_, 3), (_, 4): return few
        default: return many
        }
    }
}

/// One fault on its own: everything the databases say about it, and the option
/// to clear just this one.
struct FaultDetailScreen: View {
    @ObservedObject var session: ElmSession
    @ObservedObject var model: FaultTreeModel
    let node: EcuNode
    let dtc: Dtc

    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    private var detail: FaultDetail { model.catalogue.detail(dtc, of: node.target) }

    var body: some View {
        List {
            Section {
                Text(detail.description ?? "нет описания в базе Diagbox")
                    .font(.body)
            }
            Section {
                LabeledContent("Блок", value: model.catalogue.title(of: node.target))
                LabeledContent("Код", value: dtc.display)
                if let failureText = detail.failureText {
                    LabeledContent("Характер", value: failureText)
                }
                LabeledContent("Состояние",
                               value: detail.statusText ?? "байт \(dtc.status)")
                if detail.statusText != nil {
                    LabeledContent("Байт статуса", value: dtc.status)
                        .font(.caption.monospaced())
                }
            }
            if node.target.clear != nil {
                Section {
                    Button("Стереть эту ошибку", role: .destructive) { confirming = true }
                        .disabled(model.busy || !session.isConnected)
                } footer: {
                    Text("Стирается только этот код: запрос тот же, что и для всей "
                         + "памяти, но группой указана сама ошибка. Не каждый блок "
                         + "это умеет — тот, который не умеет, ответит отказом.")
                }
            }
        }
        .navigationTitle(dtc.display)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Стереть \(dtc.display)?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Стереть", role: .destructive) {
                Task {
                    await model.clear(dtc, of: node, session: session)
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}
