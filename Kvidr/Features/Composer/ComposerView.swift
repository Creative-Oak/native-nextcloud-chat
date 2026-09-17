import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The compose area: reply/edit context, the text field, and the send affordance.
struct ComposerView: View {
    @Bindable var model: ChatModel
    @Binding var isFocused: Bool

    @Environment(\.preferences) private var preferences
    @Environment(AppModel.self) private var app
    @State private var height: CGFloat = ComposerTextView.minimumHeight
    /// The times named in what is being typed. Owned here, because it is a property of the
    /// draft rather than of the conversation.
    @State private var composerIntelligence = ComposerIntelligence()
    @State private var smartReplies = SmartReplyModel()
    /// Waved away for this conversation: the out-of-office suggestion doesn't come back
    /// until you open it again.
    @State private var didDismissAbsenceSuggestion = false
    @State private var isShowingNewPoll = false
    /// Made the first time the record button is pressed.
    @State private var recorder: VoiceRecorder?

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
                    title: model.isReplyingPrivately
                        ? "Replying privately to \(replyingTo.actor.resolvedDisplayName)"
                        : "Replying to \(replyingTo.actor.resolvedDisplayName)",
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
                if let recorder, recorder.phase != .idle {
                    VoiceRecordingBar(recorder: recorder) {
                        let replyTo = model.replyingTo.flatMap { $0.token == model.token ? $0.messageID : nil }
                        recorder.send(replyTo: replyTo)
                        model.cancelReply()
                    }
                } else {
                    if let sendAt = suggestedAbsenceSendTime, let absence = model.absence {
                        AbsenceSendLaterBar(
                            name: model.conversation.displayName,
                            absence: absence,
                            sendAt: sendAt,
                            onSchedule: { model.beginSendLater(at: sendAt) },
                            onDismiss: { didDismissAbsenceSuggestion = true }
                        )
                    } else if !smartReplies.replies.isEmpty {
                        SmartReplyBar(replies: smartReplies.replies, onPick: useSuggestedReply)
                    }
                    editor
                }
            } else {
                unavailableNotice
            }
        }
        .task(id: model.token) { startIntelligence() }
        // The scanner runs on the draft as it changes; the model, when there is one, a
        // moment behind it. Both are cancelled and restarted by `update`, so a fast typist
        // never has more than one request in flight.
        .onChange(of: model.draftText) { _, text in
            composerIntelligence.update(for: text)
            if !text.isEmpty { smartReplies.dismiss() }
        }
        .onChange(of: model.messages.last?.messageID) { smartReplies.update(for: model) }
        .onChange(of: model.replyingTo?.messageID) { smartReplies.update(for: model) }
        // No bar. The composer is floating chrome now: the transcript slides under it and
        // shows through the glass, which is what the material is for.
        .overlay(alignment: .bottomLeading) { mentionSuggestions }
        // Leaving the conversation throws an unsent recording away, file and all.
        .onDisappear { recorder?.discard() }
        .animation(.smooth(duration: 0.2), value: recorder?.phase)
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
                            if model.canSchedule, model.editing == nil {
                                Divider()
                                // Straight to the capsule in the field; the quick times are in there.
                                Button("Send Later", systemImage: "clock") { model.beginSendLater() }
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
            NewPollSheet(
                session: model.session,
                token: model.conversation.token,
                conversationSoFar: pollSourceText
            ) {
                // Nothing to insert here: creating a poll posts the message itself, and the
                // sync loop brings it back like anyone else's.
            }
        }
    }

    /// Text, character count and send, all inside one glass capsule — the field is a
    /// single control rather than a row of parts spread across the window.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Send Later sits inside the field, above the words it will send — as in Messages.
            // The room under it keeps it clear of the send button's circle.
            if let armed = model.armedReminder {
                ArmedReminderPill(armed: armed) { model.armedReminder = nil }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .padding(.leading, -5)
                    .padding(.trailing, 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.sendLater != nil {
                // 7pt from the field's edge on every side it touches: the field pads its
                // content 12 leading, 6 trailing and 5 top, so these even that out.
                SendLaterPill(model: model)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .padding(.leading, -5)
                    .padding(.trailing, 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
                dateHighlights: preferences?.suggestsTimes == false ? [] : composerIntelligence.dates.map(\.range),
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
                },
                onActivateHighlight: { offset in armReminder(at: offset) }
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
                // Both buttons are always laid out, one of them invisible, so the field is the
                // same height either way. Swapping one for the other changed it by a few points,
                // and the bottom-anchored transcript jumped when the first letter was typed.
                ZStack {
                    Button {
                        startRecording()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Record a voice message")
                    .accessibilityLabel("Record a voice message")
                    .opacity(showsRecordButton ? 1 : 0)
                    .allowsHitTesting(showsRecordButton)
                    .accessibilityHidden(!showsRecordButton)

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
                    .opacity(showsRecordButton ? 0 : 1)
                    .allowsHitTesting(!showsRecordButton)
                    .accessibilityHidden(showsRecordButton)
                }
            }
        }
        // A little more room under the words while Send Later is open, so the field holds
        // the outline without looking packed.
        .padding(.bottom, model.sendLater != nil ? 4 : 0)
        }
        .animation(.smooth(duration: 0.2), value: model.sendLater != nil)
        .animation(.smooth(duration: 0.2), value: model.armedReminder)
        .animation(.smooth(duration: 0.2), value: suggestedAbsenceSendTime)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        // Never shorter than the round buttons beside it: the three read as one band.
        .frame(minHeight: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
    }

    /// Hands both helpers what this Mac and this user allow, and asks for replies to
    /// whatever is already on screen.
    private func startIntelligence() {
        app.intelligence.refreshReadiness()
        // A session carries its conversation with it, and the next conversation is none of
        // the last one's business.
        app.intelligence.forgetContext()

        composerIntelligence.intelligence = app.intelligence
        composerIntelligence.isEnabled = preferences?.suggestsTimes ?? true
        composerIntelligence.update(for: model.draftText)

        didDismissAbsenceSuggestion = false

        smartReplies.intelligence = app.intelligence
        smartReplies.isEnabled = preferences?.suggestsReplies ?? true
        smartReplies.update(for: model)
    }

    /// When to offer holding this message until the person you are writing to is back.
    ///
    /// Only once there is something to hold, and only while it would actually be sent into
    /// their absence: with Send Later already open, or the composer in the middle of an
    /// edit, there is nothing helpful to say.
    private var suggestedAbsenceSendTime: Date? {
        guard !didDismissAbsenceSuggestion, model.canSchedule else { return nil }
        guard model.sendLater == nil, model.editing == nil, model.editingScheduled == nil else { return nil }
        guard !model.trimmedDraft.isEmpty, !model.attachments.hasStaged else { return nil }
        return model.absence?.firstMorningBack()
    }

    /// The recent conversation as plain lines, for the poll sheet to read a question out of.
    ///
    /// Nil rather than empty when there is nothing to read: the sheet hides its suggestion
    /// button entirely rather than offering one that can only disappoint. Sensitive
    /// conversations are never read.
    private var pollSourceText: (() -> String)? {
        guard !model.conversation.isSensitive else { return nil }
        let recent = model.messages
            .filter { !$0.isSystem && !$0.isDeleted && !$0.text.isEmpty }
            .suffix(20)
        guard recent.count >= 3 else { return nil }
        return {
            recent
                .map { "\($0.actor.resolvedDisplayName): \($0.text.prefix(300))" }
                .joined(separator: "\n")
        }
    }

    /// A suggested reply goes into the field with the caret after it, never straight to
    /// the server. One click has never sent a message in this app and this isn't the
    /// feature to start with.
    private func useSuggestedReply(_ reply: String) {
        model.draftText = reply
        model.caretRequest = reply.count
        isFocused = true
        smartReplies.dismiss()
    }

    /// A click on an underlined time: the reminder is armed, not set. It has nothing to
    /// hang on until the message exists — see ``ArmedReminder``.
    private func armReminder(at offset: Int) {
        guard let expression = composerIntelligence.expression(atCharacter: offset) else { return }
        model.armedReminder = ArmedReminder(date: expression.date, phrase: expression.phrase)
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

    /// Nothing typed, nothing attached, not editing — and a server that takes files.
    private var showsRecordButton: Bool {
        model.draftText.isEmpty && !model.attachments.hasStaged && model.editing == nil
            && model.sendLater == nil && model.attachments.canAttach
    }

    private func startRecording() {
        let recorder = self.recorder ?? VoiceRecorder(
            session: model.session,
            token: model.token,
            conversationName: model.conversation.displayName
        )
        self.recorder = recorder
        Task { await recorder.start() }
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
        } else if model.sendLater != nil {
            model.cancelSendLater()
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

