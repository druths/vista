import SwiftUI

struct NotesView: View {
    @Environment(AppModel.self) private var model

    @State private var sort = SortOption()
    @State private var newlyCreated: String?
    @State private var loading = true

    /// Row identity for pushing the editor. A distinct type from the `String`
    /// used for a freshly created note, so the two destinations don't collide.
    private struct NoteRef: Hashable { let name: String }

    private var store: NoteStore { model.notes }

    private var ordered: [NoteStore.Entry] {
        // Notes deleted here are still cached until the server is told, but
        // they shouldn't linger on screen.
        let items = store.entries.filter { !$0.deleted }
        switch sort.field {
        case .name:
            return items.sorted {
                sort.ascending
                    ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        case .date:
            return items.sorted { sort.ascending ? $0.modified < $1.modified : $0.modified > $1.modified }
        }
    }

    var body: some View {
        List {
            if let message = store.lastError {
                // Conflicts surface here: a copy has been filed and the reader
                // needs to know it exists.
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message).font(.callout)
                        Spacer(minLength: 0)
                        Button("Dismiss") { store.lastError = nil }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            }

            ForEach(ordered) { entry in
                NavigationLink(value: NoteRef(name: entry.localName)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.title).font(.body.weight(.medium))
                            if entry.pending {
                                // Held locally, not yet on the server.
                                Image(systemName: "arrow.up.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Waiting to sync")
                            }
                        }
                        if !preview(entry).isEmpty {
                            Text(preview(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(entry.modified.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                let names = offsets.map { ordered[$0].localName }
                Task { for name in names { await store.delete(name: name) } }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && ordered.isEmpty {
                ProgressView()
            } else if ordered.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "note.text")
                } description: {
                    Text("Capture something with the compose button.")
                } actions: {
                    Button("New note") { Task { await create() } }
                }
            }
        }
        .navigationTitle("Notes")
        .navigationDestination(for: NoteRef.self) { ref in
            NoteEditorView(name: ref.name)
        }
        .navigationDestination(item: $newlyCreated) { name in
            NoteEditorView(name: name)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SortMenu(sort: $sort) }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await create() }
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
        }
        .refreshable { await store.refresh() }
        .task {
            // The cache is already on screen; this reconciles with the server
            // and pushes anything that was written offline.
            await store.refresh()
            loading = false
        }
    }

    /// Capture should be one tap: make an untitled note and open it straight
    /// away rather than asking for a name first. Works offline — the note is
    /// created locally and pushed when there's a server to push to.
    private func create() async {
        newlyCreated = await store.create(title: "", content: "")
    }

    /// First meaningful line, with markdown chrome stripped and a heading that
    /// merely repeats the title skipped.
    private func preview(_ entry: NoteStore.Entry) -> String {
        var lines: [String] = []
        for raw in entry.content.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#->*+".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            if lines.isEmpty, line.caseInsensitiveCompare(entry.title) == .orderedSame { continue }
            lines.append(line)
            if lines.joined(separator: " ").count > 120 { break }
        }
        return String(lines.joined(separator: " ").prefix(120))
    }
}
