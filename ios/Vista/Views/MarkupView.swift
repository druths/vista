import QuickLook
import SwiftUI

/// The system Markup editor, presented over a brief.
///
/// This is Apple's own Markup UI by way of QuickLook rather than a
/// reimplementation on PencilKit: the pen, highlighter, shapes, text boxes and
/// Apple Pencil behaviour all come from the system and stay current with it.
///
/// The file passed in is edited **in place**, so it must be a private
/// throwaway copy — never the cached original. The edited bytes are handed
/// back through `onSave`, and the server writes them to a sidecar so the brief
/// on the Ark side is never overwritten either.
struct MarkupView: UIViewControllerRepresentable {
    let url: URL
    let onSave: (Data) -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onSave: onSave, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.finish)
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private let url: URL
        private let onSave: (Data) -> Void
        private let onFinish: () -> Void

        init(url: URL, onSave: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
            self.url = url
            self.onSave = onSave
            self.onFinish = onFinish
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        /// Turns on the Markup affordance. `.updateContents` edits the file we
        /// handed over, which is a copy made for exactly this purpose.
        func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .updateContents
        }

        func previewController(_ controller: QLPreviewController,
                               didUpdateContentsOf previewItem: QLPreviewItem) {
            guard let data = try? Data(contentsOf: url) else { return }
            onSave(data)
        }

        /// Called when QuickLook chooses to write the edit elsewhere (it may
        /// decline to modify the original for some file types).
        func previewController(_ controller: QLPreviewController,
                               didSaveEditedCopyOf previewItem: QLPreviewItem,
                               at modifiedContentsURL: URL) {
            guard let data = try? Data(contentsOf: modifiedContentsURL) else { return }
            onSave(data)
        }

        @objc func finish() { onFinish() }
    }
}
