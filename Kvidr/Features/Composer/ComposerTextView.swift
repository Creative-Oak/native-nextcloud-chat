import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)

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
    var onPasteImage: (PlatformImage) -> Void
    /// Files copied in Finder.
    var onPasteFiles: ([URL]) -> Void

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
        textView.string = text

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.onPasteImage = { [weak coordinator] image in coordinator?.parent.onPasteImage(image) }
        textView.onPasteFiles = { [weak coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
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

/// The composer's text view, which knows that a pasted picture is an attachment.
///
/// `readSelection(from:type:)` rather than overriding `paste(_:)`: it is the documented
/// place to take a flavour off the pasteboard that the text system would otherwise ignore,
/// and it covers dropping onto the field as well as pasting into it.
private final class ComposerNSTextView: NSTextView {
    var onPasteImage: ((NSImage) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?

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
#else

/// The text field you actually type into — the iPhone and iPad half.
///
/// `UITextView` rather than `TextEditor`, for the same reasons as the Mac's `NSTextView`:
/// the composer needs to own paste (a picture becomes an attachment), grow to a ceiling and
/// then scroll, and — with a hardware keyboard — send on Return, cancel on Escape and step
/// through the mention list with the arrow keys. The on-screen keyboard's Return is a line
/// break, as in Messages; the send button sends.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    @Binding var caret: Int
    @Binding var caretRequest: Int?

    var placeholder: String
    var isEnabled: Bool
    var sendsOnReturn: Bool
    var isSuggesting: Bool

    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEditPrevious: () -> Void
    var onMoveSuggestion: (Int) -> Void
    var onAcceptSuggestion: () -> Void
    var onPasteImage: (PlatformImage) -> Void
    var onPasteFiles: ([URL]) -> Void

    static let minimumHeight: CGFloat = 24
    static let maximumHeight: CGFloat = 140

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        // Zero padding puts the caret at the leading edge, where the placeholder draws.
        textView.textContainer.lineFragmentPadding = 0
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.dataDetectorTypes = []
        textView.spellCheckingType = .yes
        textView.isScrollEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.text = text

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.coordinator = coordinator
        textView.onPasteImage = { [weak coordinator] image in coordinator?.parent.onPasteImage(image) }
        textView.onPasteFiles = { [weak coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
        Task { @MainActor in coordinator.updateHeight() }
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
            context.coordinator.updateHeight()
        }
        textView.isEditable = isEnabled

        if let requested = caretRequest {
            let location = textView.text.utf16Offset(forCharacterOffset: requested)
            textView.selectedRange = NSRange(location: location, length: 0)
            Task { @MainActor in caretRequest = nil }
        }

        if isFocused, !textView.isFirstResponder {
            Task { @MainActor in
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
            }
        } else if !isFocused, textView.isFirstResponder {
            Task { @MainActor in textView.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.parent.measuredHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        weak var textView: UITextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.caret = textView.text.characterOffset(forUTF16Offset: textView.selectedRange.location)
            updateHeight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let location = textView.text.characterOffset(forUTF16Offset: textView.selectedRange.location)
            if parent.caret != location { parent.caret = location }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // The on-screen keyboard's Return picks the highlighted name while the mention
            // list is open, rather than breaking the line under it.
            if text == "\n", parent.isSuggesting {
                parent.onAcceptSuggestion()
                return false
            }
            return true
        }

        // Hardware keyboard, routed here by the text view's key commands.

        func returnPressed(shift: Bool) -> Bool {
            if parent.isSuggesting {
                parent.onAcceptSuggestion()
                return true
            }
            if parent.sendsOnReturn != shift {
                parent.onSubmit()
                return true
            }
            return false
        }

        func escapePressed() {
            parent.onCancel()
        }

        func arrowPressed(up: Bool) -> Bool {
            if parent.isSuggesting {
                parent.onMoveSuggestion(up ? -1 : 1)
                return true
            }
            if up, textView?.text.isEmpty == true {
                parent.onEditPrevious()
                return true
            }
            return false
        }

        func tabPressed() -> Bool {
            guard parent.isSuggesting else { return false }
            parent.onAcceptSuggestion()
            return true
        }

        /// Grows to fit, up to a ceiling, then scrolls.
        func updateHeight() {
            guard let textView else { return }
            let width = textView.bounds.width > 0 ? textView.bounds.width : 280
            let used = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let clamped = min(max(used, ComposerTextView.minimumHeight), ComposerTextView.maximumHeight)
            textView.isScrollEnabled = used > ComposerTextView.maximumHeight
            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
        }
    }
}

/// The composer's text view: a pasted picture or file is an attachment, and a hardware
/// keyboard's Return, Escape, Tab and arrows go to the composer before the text system.
final class ComposerUITextView: UITextView {
    var onPasteImage: ((PlatformImage) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    weak var coordinator: ComposerTextView.Coordinator?

    private var lastLaidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // The first measurement happens before the view has a width; measure again once
        // it does, so a restored draft opens at its real height.
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            coordinator?.updateHeight()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        let fileURLs = (pasteboard.urls ?? []).filter(\.isFileURL)
        if !fileURLs.isEmpty {
            onPasteFiles?(fileURLs)
            return
        }
        if pasteboard.hasImages, let image = pasteboard.image {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleReturn)),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftReturn)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
        ]
        // Ahead of the text system, which would otherwise take Return as a line break.
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func handleReturn() {
        if coordinator?.returnPressed(shift: false) != true { insertText("\n") }
    }

    @objc private func handleShiftReturn() {
        if coordinator?.returnPressed(shift: true) != true { insertText("\n") }
    }

    @objc private func handleEscape() {
        coordinator?.escapePressed()
    }

    @objc private func handleUp() {
        if coordinator?.arrowPressed(up: true) != true { moveCaret(up: true) }
    }

    @objc private func handleDown() {
        if coordinator?.arrowPressed(up: false) != true { moveCaret(up: false) }
    }

    @objc private func handleTab() {
        if coordinator?.tabPressed() != true { insertText("\t") }
    }

    /// Ordinary caret movement, for when the composer didn't want the arrow key.
    private func moveCaret(up: Bool) {
        guard let range = selectedTextRange else { return }
        let target = position(from: range.start, in: up ? .up : .down, offset: 1)
            ?? (up ? beginningOfDocument : endOfDocument)
        selectedTextRange = textRange(from: target, to: target)
    }
}
#endif
