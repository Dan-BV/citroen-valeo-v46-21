import SwiftUI

/// The main screen: every parameter the profile knows, grouped by the page it
/// is read from, with its live value.
///
/// No dashboard, like the web version - a scrollable list, and a tap on a
/// numeric parameter opens its curve. The page header carries the switch that
/// matters for speed: a page nothing is selected from is not asked for at all,
/// and its measured round trip is shown right there so the cost is visible.
struct ParameterList: View {
    @ObservedObject var session: ElmSession
    let profile: Profile

    /// Whether every parameter is offered with a switch, or only the chosen
    /// ones are shown with their values. Owned by the screen around, which
    /// keeps the toolbar button and the advice strip for it.
    @Binding var editing: Bool

    @State private var query = ""

    var body: some View {
        List {
            ForEach(profile.pages, id: \.request) { page in
                if !visibleFields(of: page).isEmpty {
                    Section {
                        ForEach(visibleFields(of: page), id: \.key) { field in
                            row(field, page)
                        }
                    } header: {
                        header(page)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Параметр")
    }

    // MARK: - rows

    @ViewBuilder
    private func row(_ field: Profile.Field, _ page: Profile.Page) -> some View {
        if editing {
            Button {
                session.toggle(field)
            } label: {
                HStack {
                    Image(systemName: session.isSelected(field.key)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(session.isSelected(field.key) ? Color.accentColor : .secondary)
                    Text(field.label)
                    Spacer()
                    Text(field.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else if field.kind == .numeric {
            NavigationLink {
                GraphScreen(session: session, field: Readout(field))
            } label: {
                valueRow(field)
            }
        } else {
            valueRow(field)
        }
    }

    private func valueRow(_ field: Profile.Field) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(field.label)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(shown(field))
                .font(.callout.monospacedDigit())
                .foregroundStyle(session.values[field.key]?.valid == true ? .primary : .secondary)
        }
    }

    private func header(_ page: Profile.Page) -> some View {
        HStack(spacing: 8) {
            Text(page.title.isEmpty ? (page.id ?? page.request) : page.title)
            Spacer()
            if let ms = session.lastPageMs(page.request) ?? session.plan.cost(of: page) {
                Text("\(ms) мс")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if session.deadPages.contains(page.request) {
                Text("нет ответа")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if editing {
                // What the page costs against what it delivers: the trade the
                // reader is actually making.
                let use = session.wantedOn(page)
                Text("\(use.wanted)/\(use.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(use.wanted == 0 ? .secondary : .primary)
                periodMenu(page)
                Toggle("", isOn: Binding(
                    get: { page.params.contains { session.isSelected($0.key) } },
                    set: { session.setPage(page, on: $0) }
                ))
                .labelsHidden()
            } else if session.periodOf(page) > 1 {
                // A page read every N cycles is showing values up to N cycles
                // old, which is worth saying out loud.
                Text("1/\(session.periodOf(page))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// How often this page is asked for. Dividing a heavy page's rate is the
    /// other lever besides dropping it: its cost enters the cycle divided by
    /// this number.
    private func periodMenu(_ page: Profile.Page) -> some View {
        Menu {
            ForEach(PagePlan.choices, id: \.self) { choice in
                Button {
                    session.setPeriod(choice, for: page)
                } label: {
                    if choice == session.periodOf(page) {
                        Label(label(choice), systemImage: "checkmark")
                    } else {
                        Text(label(choice))
                    }
                }
            }
        } label: {
            Text(label(session.periodOf(page)))
                .font(.caption2.monospacedDigit())
        }
    }

    private func label(_ period: Int) -> String {
        period == 1 ? "каждый" : "1/\(period)"
    }

    // MARK: -

    /// In edit mode everything is offered; otherwise only what is selected, so
    /// the list is what is actually being read.
    private func visibleFields(of page: Profile.Page) -> [Profile.Field] {
        page.params.filter { field in
            if !editing, !session.isSelected(field.key) { return false }
            guard !query.isEmpty else { return true }
            return field.label.localizedCaseInsensitiveContains(query)
                || field.key.localizedCaseInsensitiveContains(query)
        }
    }

    private func shown(_ field: Profile.Field) -> String {
        Readout(field).text(session.values[field.key])
    }
}
