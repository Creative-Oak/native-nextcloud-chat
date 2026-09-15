import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The compose area: reply/edit context, the text field, and the send affordance.
struct ComposerView: View {
    @Bindable var model: ChatModel
    @Binding var isFocused: Bool

    @Environment(\.preferences) private var preferences
    @State private var height: CGFloat = ComposerTextView.minimumHeight
    @State private var isShowingNewPoll = false

    var body: some View {
        VStack(spacing: 0) {
            AttachmentTray(queue: model.attachments)

            if !model.attachments.pendingPastedFiles.isEmpty {
                PastedFilesBar(
                    files: model.attachments.pendingPastedFiles,
                    onAttach: { model.attachments.confirmPastedFiles() },
                    onCancel: { model.attachments.discardPastedFiles() }
                )
            }

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
                AttachmentMenu(queue: model.attachments, destination: model.conversation.displayName) {
                    AnyView(
                        // Not just the capability: Talk refuses a poll in anything that is not
                        // a group or public conversation, so in a direct message the item
                        // would be there only to be rejected.
                        Group {
                            if model.capabilities.supportsPolls, model.conversation.type.allowsPolls {
                                Divider()
                                Button("Poll…", systemImage: "chart.bar.doc.horizontal") { isShowingNewPoll = true }
                            }
                        }
                    )
                }
            }

            field

            // The system emoji palette, which inserts straight into the field — the
            // same thing Messages' smiley opens. The focus is moved first, and the
            // palette asked for on the next turn, so it lands in this field rather than
            // in whatever had focus a moment ago.
            EmojiPaletteButton { isFocused = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $isShowingNewPoll) {
            NewPollSheet(session: model.session, token: model.conversation.token) {
                // Nothing to insert here: creating a poll posts the message itself, and the
                // sync loop brings it back like anyone else's.
            }
        }
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
                onAcceptSuggestion: { model.acceptHighlightedMention() },
                onPasteImage: { image in
                    guard model.attachments.canAttach else { return }
                    model.attachments.enqueuePastedImage(image)
                },
                onPasteFiles: { urls in
                    guard model.attachments.canAttach else { return }
                    // Held rather than attached: a paste is the one way a file reaches the
                    // composer without anyone having pointed at it.
                    model.attachments.enqueue(pastedFiles: urls)
                }
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
        // Never shorter than the round buttons beside it: the three read as one band.
        .frame(minHeight: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
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

/// The strip that asks before a pasted file is attached.
///
/// The one attachment the app does not take on trust. Everything else was dragged, picked or
/// photographed; a `public.file-url` on the general pasteboard was put there by *something*,
/// which is not the same as by the person now pressing `⌘V` in a chat window. Naming the file
/// and waiting is the whole of the fix: the bytes are not read, so nothing has left the Mac
/// while this is on screen.
private struct PastedFilesBar: View {
    let files: [URL]
    var onAttach: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Attach", action: onAttach)
                .buttonStyle(.link)
                .font(.caption)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Don’t attach")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(.panel, cornerRadius: 12)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var title: String {
        files.count == 1 ? "Attach this pasted file?" : "Attach these \(files.count) pasted files?"
    }

    /// The names, so what is about to be uploaded is readable *before* it is uploaded —
    /// and readable in the direction it is written, since whoever planted the file also
    /// chose its name and `id_rsa\u{202E}gnp.` reads as a picture.
    private var detail: String {
        files.map { $0.lastPathComponent.withoutInvisibleMarks }.joined(separator: ", ")
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

