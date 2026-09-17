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
/// - Writing Tools works in it, for free, because it is a real `NSTextView`
/// - the times you name can be underlined where you typed them, and clicked
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
    /// The times named in the draft, as character offsets — underlined, and clickable.
    var dateHighlights: [Range<Int>] = []

    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEditPrevious: () -> Void
    var onMoveSuggestion: (Int) -> Void
    var onAcceptSuggestion: () -> Void
    /// A screenshot, or an image copied from a browser.
    var onPasteImage: (NSImage) -> Void
    /// Files copied in Finder.
    var onPasteFiles: ([URL]) -> Void
    /// A click that landed on one of `dateHighlights`, by its character offset.
    var onActivateHighlight: (Int) -> Void = { _ in }

    /// One line, and the ceiling before it starts scrolling instead of growing.
    static let minimumHeight: CGFloat = 22
    static let maximumHeight: CGFloat = 140

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than `NSTextView.scrollableTextView()`, which makes a stock
        // `NSTextView`: pasting a picture into a chat has to attach it, and the only hook
        // for that is the text view's own.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
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
        // NSTextContainer pads line fragments by 5pt unless told not to, which puts the
        // text and the caret 5pt right of where the placeholder overlay draws — so an
        // empty field shows its cursor sitting inside the first letter of the
        // placeholder. Zero here makes the text origin genuinely the leading edge.
        textView.textContainer?.lineFragmentPadding = 0
        // Proofread, Rewrite and the tone changes, in the field, from the system — nothing
        // to build and nothing to host. `.complete` asks for the full experience; macOS
        // quietly gives the limited one where the text stack can't support rewriting in
        // place, which is the right way round.
        textView.writingToolsBehavior = .complete
        textView.string = text

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.onPasteImage = { [weak coordinator] image in coordinator?.parent.onPasteImage(image) }
        textView.onPasteFiles = { [weak coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
        textView.onClickCharacter = { [weak coordinator] utf16Offset in
            guard let coordinator else { return false }
            let offset = textView.string.characterOffset(forUTF16Offset: utf16Offset)
            guard coordinator.parent.dateHighlights.contains(where: { $0.contains(offset) }) else { return false }
            coordinator.parent.onActivateHighlight(offset)
            return true
        }
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
        context.coordinator.applyHighlights(to: textView)
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
        /// What is on screen, so the attributes aren't rewritten on every SwiftUI update.
        private var appliedRanges: [NSRange] = []
        private var appliedLength = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        /// Underlines the times named in the draft, in link blue.
        ///
        /// Attributes on the text storage rather than a layer drawn over the field: the
        /// underline then moves with the words, wraps with them, and survives every edit,
        /// because it *is* the text. The field stays plain text — nothing here is ever read
        /// back out, only `textView.string` is, so the message that gets sent is the words
        /// and nothing else.
        @MainActor
        func applyHighlights(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let ranges: [NSRange] = parent.dateHighlights.compactMap { range in
                let lower = text.utf16Offset(forCharacterOffset: range.lowerBound)
                let upper = text.utf16Offset(forCharacterOffset: range.upperBound)
                guard upper > lower, upper <= storage.length else { return nil }
                return NSRange(location: lower, length: upper - lower)
            }

            // Nothing to draw and nothing left over from a moment ago.
            if ranges.isEmpty, appliedRanges.isEmpty, appliedLength == storage.length { return }
            if ranges == appliedRanges, appliedLength == storage.length { return }
            appliedRanges = ranges
            appliedLength = storage.length

            let everything = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: everything)
            storage.removeAttribute(.underlineColor, range: everything)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: everything)
            for range in ranges {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.underlineColor, value: NSColor.linkColor, range: range)
            }
            storage.endEditing()

            // Typing straight after an underlined phrase must not inherit its blue.
            textView.typingAttributes = [
                .font: textView.font ?? NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor
            ]
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
            guard let textView, let container = textView.textContainer else { return }
            guard let laidOut = Self.usedHeight(of: textView, in: container) else { return }
            let used = laidOut + textView.textContainerInset.height * 2
            let clamped = min(max(used, ComposerTextView.minimumHeight), ComposerTextView.maximumHeight)

            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
            textView.enclosingScrollView?.hasVerticalScroller = used > ComposerTextView.maximumHeight
        }

        /// How tall the text is, asking whichever text stack this view actually has.
        ///
        /// TextKit 2 is asked **first**, deliberately: reading `layoutManager` on a TextKit 2
        /// view doesn't just return nil, it drops the whole view back to TextKit 1 — and
        /// Writing Tools' full experience needs TextKit 2. Asking in the wrong order would
        /// have switched off a feature by measuring a height.
        @MainActor
        private static func usedHeight(of textView: NSTextView, in container: NSTextContainer) -> CGFloat? {
            if let layout = textView.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
                return layout.usageBoundsForTextContainer.height
            }
            guard let layoutManager = textView.layoutManager else { return nil }
            layoutManager.ensureLayout(for: container)
            return layoutManager.usedRect(for: container).height
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
    /// Asked before the caret moves. `true` means the click was the underline's, not the
    /// text system's.
    var onClickCharacter: ((Int) -> Bool)?

    /// A click on an underlined time arms a reminder instead of placing the caret. Every
    /// other click in the field behaves exactly as it always has — including the second one
    /// of a double click, which selects the word rather than firing this twice.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if onClickCharacter?(characterIndexForInsertion(at: point)) == true { return }
        super.mouseDown(with: event)
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
