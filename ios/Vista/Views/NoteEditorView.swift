import SwiftUI

struct NoteEditorView: View {
    let name: String
    let onChanged: () async -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var currentName: String
    @State private var title = ""
    @State private var text = ""
    @State private var saveState: SaveState = .saved
    @State private var loaded = false
    @State private var renaming = false
    @State private var draftTitle = ""
    /// What the server holds, so autosave can skip writes that change nothing.
    @State private var persisted = ""
    @State private var autosave: Task<Void, Never>?

    @FocusState private var editing: Bool

    private enum SaveState {
        case saved, dirty, saving, failed

        var label: String {
            switch self {
            case .saved: return "Saved"
            case .dirty: return "Unsaved"
            case .saving: return "Saving…"
            case .failed: return "Save failed"
            }
        }
    }

    init(name: String, onChanged: @escaping () async -> Void) {
        self.name = name
        self.onChanged = onChanged
        _currentName = State(initialValue: name)
    }

    var body: some View {
        Group {
            if loaded {
                TextEditor(text: $text)
                    .font(.body)
                    .monospaced()
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .onChange(of: text) { _, next in scheduleSave(next) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title.isEmpty ? "Note" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(saveState.label)
                        .font(.caption2)
                        .foregroundStyle(saveState == .saved ? Color.secondary : Color.accentColor)
                }
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
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
        .alert("Rename note", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await rename() } }
        }
        .task { await load() }
        .onDisappear {
            // Leaving the screen must not lose an edit still inside the
            // autosave debounce.
            autosave?.cancel()
            let pending = text
            if loaded, pending != persisted {
                let noteName = currentName
                Task { try? await model.client.saveNote(name: noteName, content: pending) }
            }
        }
    }

    private func load() async {
        guard !loaded else { return }
        do {
            let note = try await model.client.note(named: currentName)
            text = note.content
            persisted = note.content
            title = note.title
            loaded = true
        } catch {
            model.report(error)
        }
    }

    private func scheduleSave(_ next: String) {
        guard loaded else { return }
        saveState = next == persisted ? .saved : .dirty
        autosave?.cancel()
        guard next != persisted else { return }

        autosave = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await save(next)
        }
    }

    private func save(_ content: String) async {
        saveState = .saving
        do {
            try await model.client.saveNote(name: currentName, content: content)
            persisted = content
            saveState = text == content ? .saved : .dirty
            await onChanged()
        } catch {
            saveState = .failed
            model.report(error)
        }
    }

    private func rename() async {
        let wanted = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != title else { return }
        do {
            let renamed = try await model.client.renameNote(name: currentName, title: wanted)
            currentName = renamed.name
            title = renamed.title
            await onChanged()
        } catch {
            model.report(error)
        }
    }

    private func delete() async {
        autosave?.cancel()
        do {
            try await model.client.deleteNote(name: currentName)
            await onChanged()
            dismiss()
        } catch {
            model.report(error)
        }
    }
}
