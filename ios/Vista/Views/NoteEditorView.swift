import SwiftUI

struct NoteEditorView: View {
    let name: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var currentName: String
    @State private var text = ""
    @State private var loaded = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var autosave: Task<Void, Never>?

    private var store: NoteStore { model.notes }

    init(name: String) {
        self.name = name
        _currentName = State(initialValue: name)
    }

    private var title: String { (currentName as NSString).deletingPathExtension }

    /// Edits are written to the local cache immediately, so "saved" here means
    /// the server has it. Offline that honestly reads as waiting, not failed.
    private var status: String {
        if store.syncing { return "Syncing…" }
        guard let entry = store.entry(named: currentName) else { return "" }
        return entry.pending ? "Waiting to sync" : "Saved"
    }

    private var pending: Bool {
        store.entry(named: currentName)?.pending ?? false
    }

    var body: some View {
        Group {
            if loaded {
                MarkdownEditor(text: $text, onSave: { Task { await saveNow() } })
                    .onChange(of: text) { _, next in scheduleSave(next) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The title is the filename; tapping it renames, which is more
                // discoverable than burying rename in the overflow menu.
                Button {
                    draftTitle = title
                    renaming = true
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(title).font(.headline).lineLimit(1)
                            Image(systemName: "pencil").font(.caption2)
                        }
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(pending ? Color.accentColor : Color.secondary)
                    }
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Autosave usually gets there first; this forces a sync when it
                // didn't, or when the connection has just come back.
                Button("Save") { Task { await saveNow() } }
                    .disabled(!pending || store.syncing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        draftTitle = title
                        renaming = true
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await delete() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename note", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await rename() } }
        } message: {
            Text("This is the note's filename in the workspace. Renaming works offline.")
        }
        .task { await load() }
        .onDisappear {
            // Leaving must not lose an edit still inside the autosave debounce.
            autosave?.cancel()
            let pendingText = text
            let noteName = currentName
            if loaded {
                Task { await store.save(name: noteName, content: pendingText) }
            }
        }
    }

    private func load() async {
        guard !loaded else { return }
        text = await store.content(for: currentName)
        loaded = true
    }

    private func scheduleSave(_ next: String) {
        guard loaded else { return }
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            // Hand the save to a task of its own. The next keystroke cancels
            // the wait above, and it used to cancel the write with it — mid
            // request, after the server had already applied it. The app then
            // held a fingerprint one save out of date and its own next write
            // came back refused.
            Task { await store.save(name: currentName, content: next) }
        }
    }

    private func saveNow() async {
        autosave?.cancel()
        await store.save(name: currentName, content: text)
        await store.sync()
    }

    private func rename() async {
        let wanted = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != title else { return }
        // Save first so the rename carries the current text with it.
        autosave?.cancel()
        await store.save(name: currentName, content: text)
        currentName = await store.rename(name: currentName, to: wanted)
    }

    private func delete() async {
        autosave?.cancel()
        await store.delete(name: currentName)
        dismiss()
    }
}
