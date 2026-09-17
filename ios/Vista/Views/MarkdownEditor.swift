import SwiftUI
import UIKit

/// Editing operations the accessory bar offers, all acting on the line the
/// cursor is in.
enum MarkdownLineOp {
    case addHeading
    case removeHeading
    case toggleBullet
}

/// Pure line-prefix rewriting, kept out of the view so the behaviour is
/// obvious and doesn't depend on UIKit state.
enum MarkdownLine {
    /// Apply `op` to the line containing `selection`, returning the new text
    /// and where the cursor should end up.
    static func apply(_ op: MarkdownLineOp, to text: String, selection: NSRange) -> (String, NSRange) {
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))

        // Work on the line's content, excluding the trailing newline so the
        // paragraph structure is never disturbed.
        var contentLength = lineRange.length
        while contentLength > 0 {
            let unit = ns.character(at: lineRange.location + contentLength - 1)
            guard unit == 0x0A || unit == 0x0D else { break }
            contentLength -= 1
        }
        let contentRange = NSRange(location: lineRange.location, length: contentLength)
        let line = ns.substring(with: contentRange)

        let (indent, prefix, body) = split(line)
        let newPrefix = rewrite(prefix, op: op)
        guard newPrefix != prefix else { return (text, selection) }

        let newLine = indent + newPrefix + body
        let updated = ns.replacingCharacters(in: contentRange, with: newLine)

        // Keep the cursor where it was relative to the text, shifted by however
        // much the prefix grew or shrank.
        let delta = (newLine as NSString).length - (line as NSString).length
        let lineStart = contentRange.location
        let offsetInLine = max(0, caret - lineStart)
        let minimum = (indent + newPrefix as NSString).length
        let newOffset = max(minimum, offsetInLine + delta)
        let location = min(lineStart + newOffset, (updated as NSString).length)
        return (updated, NSRange(location: location, length: 0))
    }

    /// Break a line into leading whitespace, its markdown prefix, and the rest.
    private static func split(_ line: String) -> (indent: String, prefix: String, body: String) {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        let indent = String(line[line.startIndex..<index])
        let rest = String(line[index...])

        // Heading: one to six '#', then any spaces.
        var hashes = 0
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor] == "#", hashes < 6 {
            hashes += 1
            cursor = rest.index(after: cursor)
        }
        if hashes > 0 {
            var after = cursor
            while after < rest.endIndex, rest[after] == " " { after = rest.index(after: after) }
            return (indent, String(repeating: "#", count: hashes) + " ", String(rest[after...]))
        }

        // Bullet: -, * or + followed by a space.
        if let first = rest.first, "-*+".contains(first) {
            let afterMarker = rest.index(after: rest.startIndex)
            if afterMarker < rest.endIndex, rest[afterMarker] == " " {
                var after = afterMarker
                while after < rest.endIndex, rest[after] == " " { after = rest.index(after: after) }
                return (indent, "- ", String(rest[after...]))
            }
        }

        return (indent, "", rest)
    }

    private static func rewrite(_ prefix: String, op: MarkdownLineOp) -> String {
        let level = prefix.prefix(while: { $0 == "#" }).count
        let isBullet = prefix.hasPrefix("- ")

        switch op {
        case .addHeading:
            guard level < 6 else { return prefix }
            return String(repeating: "#", count: level + 1) + " "
        case .removeHeading:
            guard level > 0 else { return prefix }
            return level == 1 ? "" : String(repeating: "#", count: level - 1) + " "
        case .toggleBullet:
            return isBullet ? "" : "- "
        }
    }
}

/// A plain-text editor backed by `UITextView`.
///
/// SwiftUI's `TextEditor` exposes neither the selection (needed to know which
/// line the markdown buttons should act on) nor the container inset, so this
/// wraps UIKit directly and gets both, plus an accessory bar that belongs to
/// the text view rather than to SwiftUI's keyboard toolbar.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var onSave: () -> Void

    /// Blank space kept below the last line so it never sits against the
    /// keyboard. Scrollable, not typable — it is inset, not content.
    private let bottomInset: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                          weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: bottomInset, right: 8)
        // Markdown is punctuation-sensitive; curly quotes and en dashes corrupt
        // it silently.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocapitalizationType = .sentences
        view.text = text
        view.inputAccessoryView = context.coordinator.makeAccessoryBar()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.text != text else { return }
        // Replacing the text resets the selection, so put it back.
        let selection = view.selectedRange
        view.text = text
        let length = (view.text as NSString).length
        view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: UITextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            self.textView = textView
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            self.textView = textView
        }

        func makeAccessoryBar() -> UIToolbar {
            let bar = UIToolbar()
            bar.sizeToFit()
            let flexible = UIBarButtonItem(systemItem: .flexibleSpace)
            bar.items = [
                UIBarButtonItem(title: "#+", style: .plain, target: self, action: #selector(addHeading)),
                UIBarButtonItem(title: "#−", style: .plain, target: self, action: #selector(removeHeading)),
                UIBarButtonItem(title: "•", style: .plain, target: self, action: #selector(toggleBullet)),
                flexible,
                UIBarButtonItem(title: "Save", style: .plain, target: self, action: #selector(save)),
                UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                    self?.textView?.resignFirstResponder()
                }),
            ]
            return bar
        }

        @objc private func addHeading() { apply(.addHeading) }
        @objc private func removeHeading() { apply(.removeHeading) }
        @objc private func toggleBullet() { apply(.toggleBullet) }
        @objc private func save() { parent.onSave() }

        /// Edits go through the text view rather than the binding so the
        /// cursor survives; the binding is updated afterwards.
        private func apply(_ op: MarkdownLineOp) {
            guard let view = textView ?? findTextView() else { return }
            let (updated, selection) = MarkdownLine.apply(op, to: view.text, selection: view.selectedRange)
            guard updated != view.text else { return }
            view.text = updated
            view.selectedRange = selection
            parent.text = updated
        }

        private func findTextView() -> UITextView? { textView }
    }
}
