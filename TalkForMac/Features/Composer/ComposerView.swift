import AppKit
import SwiftUI

/// The compose area: reply/edit context, the text field, and the send affordance.
struct ComposerView: View {
    @Bindable var model: ChatModel
    @Binding var isFocused: Bool

    @Environment(\.preferences) private var preferences
    @State private var height: CGFloat = ComposerTextView.minimumHeight

    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo = model.replyingTo {
                ComposerContextBar(
                    symbol: "arrowshape.turn.up.left",
                    title: "Replying to \(replyingTo.actor.resolvedDisplayName)",
                    detail: model.content(for: replyingTo).preview,
                    onCancel: { model.cancelReply() }
                )
            } else if model.editing != nil {
                ComposerContextBar(
                    symbol: "pencil",
                    title: "Editing message",
                    detail: nil,
                    onCancel: { model.cancelEdit() }
                )
            }

            if model.conversation.canPostMessages {
                editor
            } else {
                unavailableNotice
            }
        }
        .background(.bar)
    }

    private var editor: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(
                text: $model.draftText,
                isFocused: $isFocused,
                measuredHeight: $height,
                placeholder: placeholder,
                isEnabled: true,
                sendsOnReturn: preferences?.sendsOnReturn ?? true,
                onSubmit: { model.send() },
                onCancel: { cancelContext() },
                onEditPrevious: { model.beginEditingLatestOwnMessage() }
            )
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if model.draftText.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                if let remaining = model.remainingCharacters {
                    Text("\(remaining)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(remaining < 0 ? .red : .secondary)
                }
                Button(action: { model.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var unavailableNotice: some View {
        HStack {
            Image(systemName: "lock")
            Text(model.conversation.isFormerOneToOne
                 ? "This person’s account was deleted. You can still read the conversation."
                 : "You don’t have permission to post in this conversation.")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        model.editing != nil ? "Edit message" : "Message \(model.conversation.displayName)"
    }

    private var sendHelp: String {
        (preferences?.sendsOnReturn ?? true)
            ? "Send (Return · Shift-Return for a new line)"
            : "Send (⌘Return)"
    }

    private func cancelContext() {
        if model.editing != nil {
            model.cancelEdit()
        } else if model.replyingTo != nil {
            model.cancelReply()
        }
    }
}

/// The strip above the field showing what you're replying to or editing.
private struct ComposerContextBar: View {
    let symbol: String
    let title: String
    let detail: String?
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Cancel (Escape)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

private struct PreferencesKey: EnvironmentKey {
    static let defaultValue: Preferences? = nil
}

extension EnvironmentValues {
    var preferences: Preferences? {
        get { self[PreferencesKey.self] }
        set { self[PreferencesKey.self] = newValue }
    }
}
