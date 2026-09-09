import PDFKit
import SwiftUI

/// PDFKit-backed reader. Used for reading; markup is handed to the system
/// Markup editor (see `MarkupView`).
struct PDFViewer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Reloading the same file would reset the reader's scroll position, so
        // only swap the document when the file actually changes (for instance
        // when toggling between the original and the marked-up copy).
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
