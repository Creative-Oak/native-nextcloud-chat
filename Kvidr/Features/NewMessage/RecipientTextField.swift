import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)

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
#else

/// The text field inside the To: band — the iPhone and iPad half.
///
/// `UITextField` for the same reason the Mac uses `NSTextField`: Backspace in an empty field
/// has to reach the chips, and on a hardware keyboard the arrows, Return and Escape have to
/// walk and pick the matches. `deleteBackward` and key commands are where UIKit offers them.
struct RecipientTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var prompt: String

    var onBackspaceIntoChips: () -> Bool
    var onMove: (Int) -> Bool
    var onAccept: () -> Bool
    var onCancel: () -> Bool

    func makeUIView(context: Context) -> RecipientUITextField {
        let field = RecipientUITextField()
        field.delegate = context.coordinator
        field.coordinator = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = prompt
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: RecipientUITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if field.placeholder != prompt { field.placeholder = prompt }
        if isFocused, !field.isFirstResponder {
            Task { @MainActor in field.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RecipientTextField

        init(_ parent: RecipientTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            _ = parent.onAccept()
            return false
        }
    }
}

final class RecipientUITextField: UITextField {
    weak var coordinator: RecipientTextField.Coordinator?

    override func deleteBackward() {
        // Only when there is nothing left to delete: otherwise Backspace is Backspace.
        if (text ?? "").isEmpty, coordinator?.parent.onBackspaceIntoChips() == true { return }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func moveUp() { _ = coordinator?.parent.onMove(-1) }
    @objc private func moveDown() { _ = coordinator?.parent.onMove(1) }
    @objc private func cancel() { _ = coordinator?.parent.onCancel() }
}
#endif
