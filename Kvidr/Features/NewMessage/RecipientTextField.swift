import AppKit
import SwiftUI

/// The text field inside the To: band.
///
/// AppKit rather than `TextField`, for one reason: the keys that drive the matches below it.
/// A focused `NSTextField` handles Backspace, the arrows, Return and Escape itself, and
/// SwiftUI's `onKeyPress` never sees them — so backspacing a chip away, or walking the
/// matches, silently did nothing. `doCommandBySelector` is where AppKit offers those to the
/// delegate before acting on them, which is the only place to intercept them.
struct RecipientTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var prompt: String

    /// Backspace with the cursor at the very start and nothing to delete.
    var onBackspaceIntoChips: () -> Bool
    var onMove: (Int) -> Bool
    var onAccept: () -> Bool
    var onCancel: () -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.placeholderString = prompt
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }

        if isFocused, field.window?.firstResponder !== field.currentEditor() {
            // Next turn: a field still being laid out is not in the responder chain yet.
            Task { @MainActor in _ = field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RecipientTextField

        init(_ parent: RecipientTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        /// Where the keys arrive before the field acts on them. Returning `true` means we
        /// handled it and the field should not.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)):
                // Only when there is nothing left to delete: otherwise Backspace is Backspace.
                guard textView.string.isEmpty else { return false }
                return parent.onBackspaceIntoChips()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onAccept()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCancel()
            default:
                return false
            }
        }
    }
}
