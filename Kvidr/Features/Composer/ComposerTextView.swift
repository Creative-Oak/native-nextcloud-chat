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
    /// A screenshot, or an image copied from a browser.
    var onPasteImage: (NSImage) -> Void
    /// Files copied in Finder.
    var onPasteFiles: ([URL]) -> Void
    /// A Genmoji from the emoji picker: its picture, and what it shows.
    var onGenmoji: (NSImage, String) -> Void = { _, _ in }
    /// What's selected, in UTF-16 — for translating only that.
    var onSelectionChange: (NSRange) -> Void = { _ in }

    /// One line, and the ceiling before it starts scrolling instead of growing.
    static let minimumHeight: CGFloat = 22
    static let maximumHeight: CGFloat = 140

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than `NSTextView.scrollableTextView()`, which makes a stock
        // `NSTextView`: pasting a picture into a chat has to attach it, and the only hook
        // for that is the text view's own.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        let textView = ComposerNSTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.drawsBackground = false
        // Clear as well as not drawn: Writing Tools paints the text view's background colour —
        // white, unless told otherwise — behind the words it's working on, and on the glass
        // capsule that shows as a white slab.
        textView.backgroundColor = .clear
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
        // Apple Intelligence's Writing Tools — proofread, rewrite, make friendlier — in full,
        // right in the field. Plain text back: a Talk message is Markdown text, and a list or a
        // table Writing Tools made would arrive as attributes the send would drop.
        textView.writingToolsBehavior = .complete
        textView.allowedWritingToolsResultOptions = [.plainText]
        textView.textContainer?.widthTracksTextView = true
        // NSTextContainer pads line fragments by 5pt unless told not to, which puts the
        // text and the caret 5pt right of where the placeholder overlay draws — so an
        // empty field shows its cursor sitting inside the first letter of the
        // placeholder. Zero here makes the text origin genuinely the leading edge.
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.onPasteImage = { [weak coordinator] image in coordinator?.parent.onPasteImage(image) }
        textView.onPasteFiles = { [weak coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
        textView.onGenmoji = { [weak coordinator] image, description in coordinator?.parent.onGenmoji(image, description) }
        Task { @MainActor in coordinator.updateHeight() }
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
            let location = textView.string.utf16Offset(forCharacterOffset: requested)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // Clear the request outside the update pass.
            Task { @MainActor in caretRequest = nil }
        }

        if isFocused, textView.window?.firstResponder !== textView {
            Task { @MainActor in
                _ = textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
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
            parent.caret = textView.string.characterOffset(forUTF16Offset: textView.selectedRange().location)
            updateHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.string.characterOffset(forUTF16Offset: textView.selectedRange().location)
            if parent.caret != location { parent.caret = location }
            parent.onSelectionChange(textView.selectedRange())
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        /// Writing Tools is rewriting the field: Return belongs to it, not to sending.
        private var isWritingTools = false

        func textViewWritingToolsWillBegin(_ textView: NSTextView) {
            isWritingTools = true
        }

        func textViewWritingToolsDidEnd(_ textView: NSTextView) {
            isWritingTools = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Mid-rewrite, a Return would send words that are still changing.
            if isWritingTools || textView.isWritingToolsActive { return false }
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

/// The composer's text view, which knows that a pasted picture is an attachment.
///
/// `readSelection(from:type:)` rather than overriding `paste(_:)`: it is the documented
/// place to take a flavour off the pasteboard that the text system would otherwise ignore,
/// and it covers dropping onto the field as well as pasting into it.
private final class ComposerNSTextView: NSTextView {
    var onPasteImage: ((NSImage) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onGenmoji: ((NSImage, String) -> Void)?

    /// Genmoji: the emoji picker offers to make one only to a field that says it takes them.
    override var supportsAdaptiveImageGlyph: Bool { true }

    /// A Talk message is plain text, with no room for a picture in a line. So a Genmoji isn't
    /// put in the words: it goes with the message as a picture of its own, the way a pasted
    /// one does — which every Talk app can show.
    override func insert(_ adaptiveImageGlyph: NSAdaptiveImageGlyph, replacementRange: NSRange) {
        guard let image = Self.largestImage(adaptiveImageGlyph.imageContent) else { return }
        onGenmoji?(image, adaptiveImageGlyph.contentDescription)
    }

    /// A Genmoji comes in several sizes, for several text sizes; the biggest makes the best
    /// picture.
    private static func largestImage(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let biggest = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        guard let biggest else { return image }
        let single = NSImage(size: NSSize(width: biggest.pixelsWide, height: biggest.pixelsHigh))
        single.addRepresentation(biggest)
        return single
    }

    /// Ours first, because the text system takes the first flavour it recognises. A
    /// screenshot's pasteboard carries nothing else, but an image copied from a browser
    /// also carries its URL as a string — and pasting that as text, when Messages would
    /// have attached the picture, is the wrong end of the choice.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .fileURL:
            // File URLs only, and nothing else riding along. Without the option this reads
            // *every* URL on the pasteboard, not just the flavour that brought us here, so
            // a web link sitting beside the file would be staged too — and the upload path
            // fetches whatever URL it is handed.
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = (pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
            if !urls.isEmpty {
                onPasteFiles?(urls)
                return true
            }
        case .png, .tiff:
            if let image = NSImage(pasteboard: pboard) {
                onPasteImage?(image)
                return true
            }
        default:
            break
        }
        // Not something we can attach after all — let the text system have it, rather than
        // swallowing the paste and leaving the field empty.
        return super.readSelection(from: pboard, type: type)
    }
}
