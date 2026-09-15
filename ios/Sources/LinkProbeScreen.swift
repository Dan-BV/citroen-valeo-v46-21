import SwiftUI

/// Walking the adapter's own module handles, for an adapter that has no CAN
/// identifiers to walk.
///
/// A ThinkDiag names modules by handle, and the capture of the official app's
/// system scan observed thirty-four of them without saying which is which. This
/// opens each in turn and asks the recognition frames the scan profile knows.
/// What comes back says three things: the handle is alive, what class of module
/// it is - several modules answer the same frames, so a class is as far as this
/// can go - and what its fault memory holds.
///
/// The fourth thing is the identification bytes, and they are the point. Sweep
/// the same car over CAN with an ELM327 and every address has its own; the
/// handle whose bytes match is that address. That pairing is what would let
/// this adapter read the whole car by name, and it cannot be worked out from
/// the capture - only from the car.
@MainActor
final class LinkProbeModel: ObservableObject {

    static let shared = LinkProbeModel()

    @Published private(set) var probes: [LinkProbe] = []
    @Published private(set) var progress: String?
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var done = false

    private var scan: ScanProfile?
    private(set) var scanFailure: String?

    init() {
        do {
            scan = try ScanProfile.bundled()
        } catch {
            scanFailure = error.localizedDescription
        }
    }

    var answered: [LinkProbe] { probes.filter(\.answered) }
    var faultCount: Int { probes.reduce(0) { $0 + $1.faults.count } }

    func sweep(_ session: ElmSession) async {
        guard !busy else { return }
        guard let scan else {
            failure = scanFailure
            return
        }
        busy = true
        failure = nil
        probes = []
        done = false
        progress = "Подготовка…"
        do {
            try await session.probeLinks(
                scan,
                onProgress: { [weak self] i, total, link in
                    self?.progress = String(format: "Канал %d из %d — #%04X", i, total, link)
                },
                onLink: { [weak self] probe in
                    self?.probes.append(probe)
                })
            done = true
        } catch {
            failure = error.localizedDescription
        }
        progress = nil
        busy = false
    }

    /// The whole sweep as text. This is the thing worth sending on: the
    /// identification bytes here and the ones a CAN sweep prints are what pair
    /// a handle with a module.
    func report() -> String {
        var lines: [String] = []
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("Каналы адаптера, \(stamp.string(from: Date()))")
        lines.append("Опрошено \(probes.count), ответили \(answered.count)")
        lines.append("")
        for probe in probes {
            guard probe.answered else {
                lines.append("\(probe.name)  молчит")
                continue
            }
            let classes = probe.candidates.map(\.family)
            var seen = Set<String>()
            let families = classes.filter { seen.insert($0).inserted }
            lines.append("\(probe.name)  распознан \(probe.reco) → "
                         + families.joined(separator: "/"))
            lines.append("    ид.: \(probe.identHex)")
            if let failure = probe.failure {
                lines.append("    чтение ошибок: \(failure)")
            } else if probe.faults.isEmpty {
                lines.append("    ошибок нет")
            } else {
                for fault in probe.faults {
                    lines.append("    \(fault.display)  статус \(fault.status)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct LinkProbeScreen: View {
    @ObservedObject var session: ElmSession
    @ObservedObject private var model = LinkProbeModel.shared

    var body: some View {
        List {
            Section {
                Text("Этот адаптер не знает CAN-адресов: он обращается к блокам "
                     + "по собственным каналам, которых в записи официального "
                     + "приложения нашлось \(session.adapterLinks.count). "
                     + "Обход открывает каждый и спрашивает кадры распознавания — "
                     + "что ответило, к какому классу блоков относится и что у "
                     + "него в памяти неисправностей.")
                    .font(.callout)
            } footer: {
                Text("Назвать блок точно этот обход не может: один и тот же кадр "
                     + "распознавания отвечают несколько блоков, а различает их "
                     + "CAN-адрес, которого здесь нет. Пара находится по байтам "
                     + "идентификации — сделайте обход по CAN с адаптером ELM327 "
                     + "и сравните их с отчётом отсюда.")
            }

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }

            if let progress = model.progress {
                Section { ProgressView(progress) }
            }

            ForEach(model.probes) { probe in
                Section { row(probe) }
            }

            Section {
                Button(model.done ? "Опросить заново" : "Опросить каналы") {
                    Task { await model.sweep(session) }
                }
                .disabled(model.busy || !session.isConnected || session.adapterLinks.isEmpty)
                if model.done {
                    ShareLink(item: model.report()) {
                        Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                if model.done {
                    Text("Ответили \(model.answered.count) из \(model.probes.count), "
                         + "ошибок всего \(model.faultCount).")
                }
            }
        }
        .navigationTitle("Каналы адаптера")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ probe: LinkProbe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(probe.name).font(.callout.monospaced().bold())
                Spacer()
                if !probe.answered {
                    Text("молчит").font(.caption).foregroundStyle(.secondary)
                } else if let failure = probe.failure {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                } else if probe.faults.isEmpty {
                    Text("ошибок нет").font(.caption).foregroundStyle(.green)
                } else {
                    Text("\(probe.faults.count)").font(.callout.bold()).foregroundStyle(.red)
                }
            }
            if probe.answered {
                Text(families(probe)).font(.callout)
                Text("распознан \(probe.reco) · ид. \(probe.identHex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                ForEach(probe.faults) { fault in
                    Text("\(fault.display) · статус \(fault.status)")
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private func families(_ probe: LinkProbe) -> String {
        var seen = Set<String>()
        let families = probe.candidates.map(\.family).filter { seen.insert($0).inserted }
        return families.isEmpty ? "неизвестный блок" : families.joined(separator: " / ")
    }
}
