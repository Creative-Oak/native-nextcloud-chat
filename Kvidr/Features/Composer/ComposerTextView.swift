import AppKit
import SwiftUI

/// The text field you actually type into.
///
/// This is AppKit rather than `TextEditor` on purpose. A chat composer has to get several
/// things exactly right that SwiftUI's text editor does not expose:
///
/// - Return sends, Shift-Return inserts a line break (and the preference can swap them)
/// - Escape cancels a reply or an edit
/// - ⌘↑ starts editing your last message when the field is empty
/// - it grows with the text and then scrolls, instead of growing forever
/// - paste, spell checking, substitutions, and the Emoji & Symbols palette all behave
///   like they do in every other Mac app, because it *is* the same text system
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    /// Where the caret is, so mention autocomplete knows which `@…` you're inside.
    @Binding var caret: Int
    /// Set by the model after it rewrites the text (accepting a mention), consumed here.
    @Binding var caretRequest: Int?

    var placeholder: String
    var isEnabled: Bool
    var sendsOnReturn: Bool
    /// While the mention list is open it owns Return, Tab, Escape and the arrow keys.
    var isSuggesting: Bool

    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEditPrevious: () -> Void
    var onMoveSuggestion: (Int) -> Void
    var onAcceptSuggestion: () -> Void

    /// One line, and the ceiling before it starts scrolling instead of growing.
    static let minimumHeight: CGFloat = 22
    static let maximumHeight: CGFloat = 140

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Smart links would turn typed URLs into attributed runs we'd then have to strip.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true

        if let requested = caretRequest {
            let clamped = min(max(requested, 0), textView.string.count)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            // Clear the request outside the update pass.
            DispatchQueue.main.async { caretRequest = nil }
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                _ = textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.caret = textView.selectedRange().location
            updateHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            if parent.caret != location { parent.caret = location }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // While the mention list is open it owns these keys — Return picks a name
            // rather than sending a half-typed message.
            if parent.isSuggesting {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMoveSuggestion(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMoveSuggestion(1)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    parent.onAcceptSuggestion()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCancel()
                    return true
                default:
                    break
                }
            }

            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.sendsOnReturn {
                    parent.onSubmit()
                    return true
                }
                return false

            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Shift-Return. Sends when the preference is inverted, otherwise a newline.
                if parent.sendsOnReturn { return false }
                parent.onSubmit()
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true

            case #selector(NSResponder.moveUp(_:)):
                // ⌘↑ only when there's nothing composed — otherwise it's ordinary caret
                // movement and stealing it would be maddening.
                if textView.string.isEmpty {
                    parent.onEditPrevious()
                    return true
                }
                return false

            default:
                return false
            }
        }

        /// Grows to fit, up to a ceiling, then scrolls.
        ///
        /// Explicitly main-actor: the delegate methods above get that inferred from
        /// NSTextViewDelegate, but this one isn't a protocol requirement, so without it
        /// the whole body reads and mutates AppKit state from a nonisolated context.
        @MainActor
        func updateHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else { return }

            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let clamped = min(max(used, ComposerTextView.minimumHeight), ComposerTextView.maximumHeight)

            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
            textView.enclosingScrollView?.hasVerticalScroller = used > ComposerTextView.maximumHeight
        }
    }
}
