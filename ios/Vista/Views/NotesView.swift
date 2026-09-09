import SwiftUI

struct NotesView: View {
    @Environment(AppModel.self) private var model

    @State private var notes: [Note] = []
    @State private var sort = SortOption()
    @State private var loading = true
    @State private var newlyCreated: String?

    var body: some View {
        List {
            ForEach(notes) { note in
                NavigationLink(value: note) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.body.weight(.medium))
                        if !note.preview.isEmpty {
                            Text(note.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(note.modified.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                Task { await delete(offsets) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && notes.isEmpty {
                ProgressView()
            } else if !loading && notes.isEmpty {
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
        .navigationDestination(for: Note.self) { note in
            NoteEditorView(name: note.name, onChanged: { await load() })
        }
        .navigationDestination(item: $newlyCreated) { name in
            NoteEditorView(name: name, onChanged: { await load() })
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
        .refreshable { await load() }
        .task(id: SortKey(field: sort.field, ascending: sort.ascending)) { await load() }
    }

    private struct SortKey: Equatable {
        let field: SortOption.Field
        let ascending: Bool
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            notes = try await model.client.notes(sort: sort).notes
        } catch {
            model.report(error)
        }
    }

    /// Capture should be one tap: make an untitled note and open it straight
    /// away rather than asking for a name first.
    private func create() async {
        do {
            let created = try await model.client.createNote(title: "", content: "")
            await load()
            newlyCreated = created.name
        } catch {
            model.report(error)
        }
    }

    private func delete(_ offsets: IndexSet) async {
        let targets = offsets.map { notes[$0] }
        do {
            for note in targets {
                try await model.client.deleteNote(name: note.name)
            }
            await load()
        } catch {
            model.report(error)
        }
    }
}
