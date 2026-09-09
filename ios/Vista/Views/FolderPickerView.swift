import SwiftUI

/// Browse the agent's workspace to choose a folder.
///
/// A mistyped path just produces an empty screen with no explanation, so
/// picking is safer than typing — especially on a phone keyboard.
struct FolderPickerView: View {
    let startPath: String
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path: String
    @State private var listing: WorkspaceListing?
    @State private var loading = true
    @State private var failure: String?

    init(startPath: String, onPick: @escaping (String) -> Void) {
        self.startPath = startPath
        self.onPick = onPick
        _path = State(initialValue: startPath)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let listing, let parent = listing.parent {
                        Button {
                            path = parent
                        } label: {
                            Label("Up one level", systemImage: "arrow.turn.left.up")
                        }
                    }
                    ForEach(listing?.directories ?? []) { entry in
                        Button {
                            path = entry.path
                        } label: {
                            Label(entry.name, systemImage: "folder")
                        }
                    }
                } header: {
                    Text(path.isEmpty ? "Workspace root" : path)
                } footer: {
                    if let listing {
                        // A PDF count is usually enough to recognise a brief folder.
                        Text(listing.pdfCount > 0
                             ? "\(listing.pdfCount) PDF\(listing.pdfCount == 1 ? "" : "s") here"
                             : "\(listing.fileCount) file\(listing.fileCount == 1 ? "" : "s") here")
                    }
                }

                if let failure {
                    Text(failure).foregroundStyle(.red).font(.callout)
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if listing?.directories.isEmpty == true {
                    ContentUnavailableView("No subfolders here", systemImage: "folder")
                }
            }
            .navigationTitle("Choose a folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onPick(path)
                        dismiss()
                    }
                    .disabled(path.isEmpty)
                }
            }
            .task(id: path) { await load() }
        }
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            listing = try await model.client.browseWorkspace(path: path)
        } catch {
            failure = error.localizedDescription
            listing = nil
        }
    }
}

/// Suggest a briefing name from its path: `briefs/ai_policy/output` reads as
/// "Ai Policy", not "Output".
func suggestBriefingName(for path: String) -> String {
    let generic: Set<String> = ["output", "outputs", "pdf", "pdfs", "files", "docs", "dist", "build"]
    let segments = path.split(separator: "/").map(String.init)
    let meaningful = segments.reversed().first { !generic.contains($0.lowercased()) }
    let base = meaningful ?? segments.last ?? ""
    let words = base.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespaces)
    guard !words.isEmpty else { return "New briefing" }
    return words.split(separator: " ").map(\.capitalized).joined(separator: " ")
}
