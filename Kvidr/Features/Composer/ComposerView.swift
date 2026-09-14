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
            AttachmentTray(queue: model.attachments)

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
        // No bar. The composer is floating chrome now: the transcript slides under it and
        // shows through the glass, which is what the material is for.
        .overlay(alignment: .bottomLeading) { mentionSuggestions }
    }

    private var editor: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.attachments.canAttach {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Attach a file (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            field
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Text, character count and send, all inside one glass capsule — the field is a
    /// single control rather than a row of parts spread across the window.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ComposerTextView(
                text: $model.draftText,
                isFocused: $isFocused,
                measuredHeight: $height,
                caret: $model.caret,
                caretRequest: $model.caretRequest,
                placeholder: placeholder,
                isEnabled: true,
                sendsOnReturn: preferences?.sendsOnReturn ?? true,
                isSuggesting: model.isShowingMentionSuggestions,
                onSubmit: { model.send() },
                onCancel: { cancelContext() },
                onEditPrevious: { model.beginEditingLatestOwnMessage() },
                onMoveSuggestion: { model.moveMentionHighlight(by: $0) },
                onAcceptSuggestion: { model.acceptHighlightedMention() }
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
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.accentColor)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendHelp)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .glass(.field, cornerRadius: 18)
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
        .glass(.panel, cornerRadius: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholder: String {
        model.editing != nil ? "Edit message" : "Message \(model.conversation.displayName)"
    }

    private var sendHelp: String {
        (preferences?.sendsOnReturn ?? true)
            ? "Send (Return · Shift-Return for a new line)"
            : "Send (⌘Return)"
    }

    /// Floats above the composer rather than pushing it down, so the text you're typing
    /// doesn't move while you're typing it.
    @ViewBuilder
    private var mentionSuggestions: some View {
        if model.isShowingMentionSuggestions {
            MentionSuggestionList(
                suggestions: model.mentionSuggestions,
                highlighted: model.highlightedMentionIndex,
                onPick: { model.accept($0) }
            )
            .padding(.leading, 12)
            .offset(y: -(height + 24))
        }
    }

    /// ⇧⌘A and the paperclip. An open panel rather than a custom picker, because the
    /// system one already knows about tags, recents, iCloud and everything else.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(model.conversation.displayName)"

        guard panel.runModal() == .OK else { return }
        model.attachments.enqueue(urls: panel.urls, replyTo: model.replyingTo?.messageID)
        model.cancelReply()
    }

    private func cancelContext() {
        if model.isShowingMentionSuggestions {
            model.dismissMentions()
            return
        }
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
        .padding(.vertical, 6)
        .glass(.panel, cornerRadius: 12)
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
