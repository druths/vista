import SwiftUI

struct BriefsView: View {
    let briefing: Briefing
    @Environment(AppModel.self) private var model

    @State private var briefs: [Brief] = []
    @State private var sort = SortOption()
    @State private var loading = true
    /// Unread by default: a briefing is a stream you work through, so what's
    /// left to read is the useful view.
    @State private var showUnreadOnly = true

    /// When every brief in a briefing carries the same title — the usual shape
    /// of a daily series — the date is what distinguishes them, so it leads.
    private var visible: [Brief] {
        showUnreadOnly ? briefs.filter { !$0.isRead } : briefs
    }

    private var seriesTitle: String? {
        // Decided from the whole briefing, not from what's on screen. Whether
        // this is a recurring series is a property of the briefing; filtering
        // down to a single unread brief must not turn its date back into a
        // repeated title.
        let titles = Set(briefs.map(\.title))
        return briefs.count > 1 && titles.count == 1 ? titles.first : nil
    }

    var body: some View {
        List {
            ForEach(visible) { brief in
                NavigationLink(value: brief) {
                    BriefRow(brief: brief, leadWithDate: seriesTitle != nil)
                }
                .contextMenu {
                    Button(brief.isRead ? "Mark as Unread" : "Mark as Read",
                           systemImage: brief.isRead ? "circle" : "checkmark.circle") {
                        Task { await setRead(brief, read: !brief.isRead) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && visible.isEmpty {
                ProgressView()
            } else if !loading && visible.isEmpty && showUnreadOnly && !briefs.isEmpty {
                // Nothing unread isn't the same as nothing here — say which,
                // and offer the way out of the filter.
                ContentUnavailableView {
                    Label("Nothing unread", systemImage: "checkmark.circle")
                } description: {
                    Text("You're up to date in \(briefing.name).")
                } actions: {
                    Button("Show All") { showUnreadOnly = false }
                }
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
                // Opening a brief marks it read, the way a mail client does.
                .task { await setRead(brief, read: true) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $showUnreadOnly) {
                        Text("Unread").tag(true)
                        Text("All").tag(false)
                    }
                } label: {
                    // A filled icon when filtering, so a short list is never
                    // mistaken for an empty briefing.
                    Label("Show", systemImage: showUnreadOnly
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                SortMenu(sort: $sort)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                        Task { await markAllRead() }
                    }
                    .disabled(briefs.allSatisfy(\.isRead))
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
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

    /// Read state lives on the server so it matches across devices. A failure
    /// here is not worth interrupting a read for — the next open marks it
    /// again.
    private func setRead(_ brief: Brief, read: Bool) async {
        guard brief.isRead != read else { return }
        try? await model.client.markBriefs(briefingID: briefing.id, keys: [brief.key], read: read)
        await load()
    }

    private func markAllRead() async {
        let unread = briefs.filter { !$0.isRead }.map(\.key)
        guard !unread.isEmpty else { return }
        try? await model.client.markBriefs(briefingID: briefing.id, keys: unread, read: true)
        await load()
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
            // Mail's convention: a dot on the left, and the space stays
            // reserved once read so titles don't shift.
            Circle()
                .fill(brief.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel(brief.isRead ? "Read" : "Unread")
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
