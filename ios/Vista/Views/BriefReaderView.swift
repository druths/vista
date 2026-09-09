import SwiftUI
import UniformTypeIdentifiers

struct BriefReaderView: View {
    let briefing: Briefing
    let brief: Brief
    /// Called after markup is saved or discarded so the list can pick up the
    /// changed state.
    let onChanged: () async -> Void

    @Environment(AppModel.self) private var model

    @State private var fileURL: URL?
    @State private var textContent: String?
    @State private var showingOriginal = false
    @State private var markupSession: MarkupSession?
    @State private var status: Status = .loading
    @State private var savingMarkup = false

    private enum Status: Equatable {
        case loading, ready, failed(String)
    }

    /// Which file to show: the marked-up copy when one exists, unless the
    /// reader has asked to see the original underneath it.
    private var displayPath: String? {
        if showingOriginal, let pdf = brief.pdfPath { return pdf }
        return brief.primaryPath ?? brief.pdfPath ?? brief.textPath
    }

    var body: some View {
        content
            .navigationTitle(brief.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: displayPath) { await loadFile() }
            .fullScreenCover(item: $markupSession) { session in
                MarkupView(
                    url: session.url,
                    onSave: { data in Task { await saveMarkup(data) } },
                    onFinish: { markupSession = nil }
                )
                .ignoresSafeArea()
            }
            .overlay { if savingMarkup { savingOverlay } }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            ProgressView("Opening…")
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't open this brief", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await loadFile() } }
            }
        case .ready:
            if let text = textContent {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if let fileURL {
                PDFViewer(url: fileURL).ignoresSafeArea(edges: .bottom)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if brief.annotated, brief.pdfPath != nil {
                Button {
                    showingOriginal.toggle()
                } label: {
                    Label(showingOriginal ? "Show markup" : "Show original",
                          systemImage: showingOriginal ? "pencil.tip.crop.circle" : "doc")
                }
            }

            if brief.isPDF {
                Button {
                    Task { await beginMarkup() }
                } label: {
                    Label("Markup", systemImage: "pencil.tip.crop.circle.badge.plus")
                }
                .disabled(status != .ready || fileURL == nil)
            }

            if brief.annotated {
                Menu {
                    Button("Discard markup", systemImage: "trash", role: .destructive) {
                        Task { await discardMarkup() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView("Saving markup…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Loading

    private func loadFile() async {
        guard let path = displayPath else {
            status = .failed("This brief has no readable file.")
            return
        }
        status = .loading
        textContent = nil

        let destination = BriefCache.location(briefingID: briefing.id, path: path, size: brief.size)
        do {
            if !BriefCache.isCached(destination) {
                try await model.client.downloadBrief(briefingID: briefing.id, path: path,
                                                     to: destination)
            }
            if path.lowercased().hasSuffix(".pdf") {
                fileURL = destination
            } else {
                textContent = try String(contentsOf: destination, encoding: .utf8)
            }
            status = .ready
        } catch {
            // Leaving the brief cancels the download; that is not a failure to
            // put on screen.
            guard !AppModel.isCancellation(error) else { return }
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Markup

    /// Copy the brief somewhere private before handing it to the system Markup
    /// editor, which edits in place — the cache copy must stay pristine.
    private func beginMarkup() async {
        guard let fileURL else { return }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Markup", isDirectory: true)
        let target = scratch.appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: target)
            markupSession = MarkupSession(url: target)
        } catch {
            model.report(error)
        }
    }

    private func saveMarkup(_ data: Data) async {
        // Markup always applies to the original brief; the server derives the
        // sidecar path, so marking up an already-annotated copy updates that
        // same sidecar rather than stacking another one.
        guard let original = brief.pdfPath else { return }
        savingMarkup = true
        defer { savingMarkup = false }
        do {
            try await model.client.saveAnnotation(briefingID: briefing.id,
                                                  originalPath: original, pdf: data)
            await onChanged()
        } catch {
            model.report(error)
        }
    }

    private func discardMarkup() async {
        guard let original = brief.pdfPath else { return }
        do {
            try await model.client.deleteAnnotation(briefingID: briefing.id, originalPath: original)
            showingOriginal = false
            await onChanged()
        } catch {
            model.report(error)
        }
    }
}

/// Identifies one markup session so it can drive `.fullScreenCover(item:)`.
/// A wrapper rather than a retroactive `Identifiable` conformance on `URL`,
/// which would be a conformance this app doesn't own.
private struct MarkupSession: Identifiable {
    let id = UUID()
    let url: URL
}
