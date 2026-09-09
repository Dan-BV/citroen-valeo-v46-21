import SwiftUI

/// The standard OBD-II set. Same shape as the proprietary list, but the cost
/// model is different and the screen says so: here the price is per *request*,
/// and up to six readings share one.
struct ObdList: View {
    @ObservedObject var session: ElmSession
    let obd: ObdSet

    @State private var editing = false

    var body: some View {
        List {
            Section {
                ForEach(visible) { param in
                    row(param)
                }
            } header: {
                Text(obd.name)
            } footer: {
                Text(footer)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editing ? "Готово" : "Выбор") { editing.toggle() }
            }
        }
    }

    // MARK: -

    private var visible: [ObdSet.Param] {
        editing ? obd.params : obd.params.filter { session.isSelected($0.key) }
    }

    /// The requests the cycle actually costs, which is what the reader can act
    /// on: six PIDs off the list may remove a whole turnaround.
    private var footer: String {
        let on = obd.params.filter { session.isSelected($0.key) }
        let perRequest = session.multiPid ? 6 : 1
        let requests = ObdReply.group(on, perRequest: perRequest).count
        let how = session.multiPid ? "до 6 за запрос" : "по одному (ЭБУ отказал в мульти-PID)"
        return "\(on.count) из \(obd.params.count) · \(requests) запрос(ов) за круг · \(how)"
    }

    @ViewBuilder
    private func row(_ param: ObdSet.Param) -> some View {
        if editing {
            Button {
                session.toggle(param.key)
            } label: {
                HStack {
                    Image(systemName: session.isSelected(param.key)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(session.isSelected(param.key) ? Color.accentColor : .secondary)
                    Text(param.label)
                    Spacer()
                    Text(param.pid)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                GraphScreen(session: session, field: Readout(param))
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(param.label).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(Readout(param).text(session.values[param.key]))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(session.values[param.key]?.valid == true
                                         ? .primary : .secondary)
                }
            }
        }
    }
}
