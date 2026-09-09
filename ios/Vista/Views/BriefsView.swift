import SwiftUI

struct BriefsView: View {
    let briefing: Briefing
    @Environment(AppModel.self) private var model

    @State private var briefs: [Brief] = []
    @State private var sort = SortOption()
    @State private var loading = true

    /// When every brief in a briefing carries the same title — the usual shape
    /// of a daily series — the date is what distinguishes them, so it leads.
    private var seriesTitle: String? {
        let titles = Set(briefs.map(\.title))
        return briefs.count > 1 && titles.count == 1 ? titles.first : nil
    }

    var body: some View {
        List {
            ForEach(briefs) { brief in
                NavigationLink(value: brief) {
                    BriefRow(brief: brief, leadWithDate: seriesTitle != nil)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && briefs.isEmpty {
                ProgressView()
            } else if !loading && briefs.isEmpty {
                ContentUnavailableView {
                    Label("No briefs here", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Vista is looking in \(briefing.path) in the agent's workspace.")
                }
            }
        }
        .navigationTitle(briefing.name)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: Brief.self) { brief in
            BriefReaderView(briefing: briefing, brief: brief, onChanged: { await load() })
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SortMenu(sort: $sort)
            }
        }
        .refreshable { await load() }
        .task(id: SortKey(briefingID: briefing.id, field: sort.field, ascending: sort.ascending)) {
            await load()
        }
    }

    /// Reloads when the briefing or the sort changes, not on every redraw.
    private struct SortKey: Equatable {
        let briefingID: Int
        let field: SortOption.Field
        let ascending: Bool
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            briefs = try await model.client.briefs(briefingID: briefing.id, sort: sort).briefs
        } catch {
            model.report(error)
        }
    }
}

private struct BriefRow: View {
    let brief: Brief
    let leadWithDate: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(leadWithDate ? dateText : brief.title)
                        .font(.body.weight(.medium))
                    if brief.annotated {
                        Image(systemName: "pencil.tip.crop.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Marked up")
                    }
                }
                HStack(spacing: 8) {
                    if !leadWithDate { Text(dateText) }
                    if !brief.folder.isEmpty { Text(brief.folder) }
                    if brief.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(brief.size),
                                                       countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var dateText: String {
        // A tilde marks a date guessed from the file's mtime rather than read
        // from its name.
        return brief.dateIsApproximate ? "\(brief.displayDate) ~" : brief.displayDate
    }
}

struct SortMenu: View {
    @Binding var sort: SortOption

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort.field) {
                ForEach(SortOption.Field.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            Picker("Order", selection: $sort.ascending) {
                Text("Newest first").tag(false)
                Text("Oldest first").tag(true)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}
