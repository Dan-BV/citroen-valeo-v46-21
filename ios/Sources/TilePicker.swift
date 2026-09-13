import SwiftUI

/// Choosing the parameter a new tile shows.
///
/// Grouped by page and priced by page, because that is what a tile actually
/// costs: a parameter from a page the cycle already asks for is free, and one
/// from a page nothing else needs adds a whole adapter turnaround to every
/// cycle. The same trade the parameter list shows, at the moment it is made.
struct TilePicker: View {

    @ObservedObject var session: ElmSession
    let profile: Profile
    /// Keys already on this board, so the same parameter is not added twice by
    /// accident. It may still be added on purpose - two tiles, two styles - and
    /// that costs nothing extra: one read, one column.
    let existing: Set<String>
    let onPick: (Profile.Field) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(profile.pages, id: \.request) { page in
                    let fields = matching(page)
                    if !fields.isEmpty {
                        Section {
                            ForEach(fields, id: \.key) { field in
                                row(field)
                            }
                        } header: {
                            header(page)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Параметр")
            .navigationTitle("Добавить плитку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    // MARK: -

    private func row(_ field: Profile.Field) -> some View {
        Button {
            onPick(field)
            dismiss()
        } label: {
            HStack {
                Text(field.label)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if existing.contains(field.key) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(field.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ page: Profile.Page) -> some View {
        HStack {
            Text(page.title.isEmpty ? (page.id ?? page.request) : page.title)
            Spacer()
            Text(price(page))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(polled(page) ? .secondary : .orange)
        }
    }

    private func polled(_ page: Profile.Page) -> Bool {
        session.polledPages.contains { $0.page.request == page.request }
    }

    /// What the first tile from this page adds to every cycle. Measured on this
    /// adapter where there is a measurement; otherwise just the honest fact
    /// that it is one more exchange.
    private func price(_ page: Profile.Page) -> String {
        if polled(page) { return "в круге" }
        if let ms = session.plan.cost(of: page) {
            let period = session.periodOf(page)
            return period > 1 ? "+\(ms / period) мс" : "+\(ms) мс"
        }
        return "+1 страница"
    }

    private func matching(_ page: Profile.Page) -> [Profile.Field] {
        page.params.filter { field in
            guard !query.isEmpty else { return true }
            return field.label.localizedCaseInsensitiveContains(query)
                || field.key.localizedCaseInsensitiveContains(query)
        }
    }
}
