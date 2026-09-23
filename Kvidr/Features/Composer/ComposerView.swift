import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The compose area: reply/edit context, the text field, and the send affordance.
struct ComposerView: View {
    @Bindable var model: ChatModel
    @Binding var isFocused: Bool
    /// Translates the draft, or the part of it that's selected, from the + menu.
    var translator: MessageTranslator?

    @Environment(\.preferences) private var preferences
    /// The draft as written, once a translation has been put in — what Show Original puts
    /// back. Nil while the draft is still as written.
    @State private var untranslated: String?
    /// The language being translated into, or last translated into, while the capsule in the
    /// field says so.
    @State private var draftTranslation: DraftTranslation?
    /// What's selected in the field, in UTF-16 — translated on its own when there is some.
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var translationLanguages: [Locale.Language] = []
    @State private var height: CGFloat = ComposerTextView.minimumHeight
    @State private var isShowingNewPoll = false
    /// Made the first time the record button is pressed.
    @State private var recorder: VoiceRecorder?
    @FocusState private var isThreadTitleFocused: Bool

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

            if showsSuggestions {
                SmartReplyChips(replies: model.smartReplies.suggestions) { reply in
                    model.draftText = reply
                    model.smartReplies.clear()
                    isFocused = true
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if model.conversation.canPostMessages {
                if let recorder, recorder.phase != .idle {
                    VoiceRecordingBar(recorder: recorder) {
                        let replyTo = model.replyingTo.flatMap { $0.token == model.token ? $0.messageID : nil }
                        recorder.send(replyTo: replyTo, threadID: model.openThread?.id)
                        model.cancelReply()
                    }
                } else {
                    editor
                }
            } else {
                unavailableNotice
            }
        }
        // No bar. The composer is floating chrome now: the transcript slides under it and
        // shows through the glass, which is what the material is for.
        .overlay(alignment: .bottomLeading) { mentionSuggestions }
        // Leaving the conversation throws an unsent recording away, file and all.
        .onDisappear { recorder?.discard() }
        // Emptied — sent, or cleared by hand — and there's no original to go back to.
        .onChange(of: model.draftText.isEmpty) { _, isEmpty in
            if isEmpty {
                untranslated = nil
                draftTranslation = nil
            }
        }
        .task { translationLanguages = await MessageTranslator.supportedLanguages() }
        // Something new from someone else, a thread opened or closed, the field emptied: new
        // replies to suggest — or none.
        .task(id: SuggestionTrigger(lastRow: model.rows.last?.id, thread: model.openThread?.id, isEmpty: model.draftText.isEmpty, isOn: preferences?.suggestsReplies ?? false)) {
            guard preferences?.suggestsReplies == true, model.draftText.isEmpty else {
                model.smartReplies.clear()
                return
            }
            model.suggestReplies(me: model.session.account.displayName)
        }
        .animation(.smooth(duration: 0.2), value: showsSuggestions)
        .animation(.smooth(duration: 0.2), value: recorder?.phase)
    }

    private var editor: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.attachments.canAttach {
                AttachmentMenu(queue: model.attachments, destination: model.conversation.displayName) {
                    attachmentMenuExtras
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

    private var showsSuggestions: Bool {
        preferences?.suggestsReplies == true && model.draftText.isEmpty && !model.smartReplies.suggestions.isEmpty
            && model.conversation.canPostMessages && model.editing == nil
    }

    private struct SuggestionTrigger: Hashable {
        var lastRow: ChatRow.ID?
        var thread: Int?
        var isEmpty: Bool
        var isOn: Bool
    }

    private func submit() {
        untranslated = nil
        draftTranslation = nil
        model.send()
    }

    /// The + menu's own items, past Photos and Files.
    private var attachmentMenuExtras: [PopUpMenuItem] {
        var items: [PopUpMenuItem] = []
        // Not just the capability: Talk refuses a poll in anything that is not a group or
        // public conversation, so in a direct message the item would be there only to be
        // rejected.
        if model.capabilities.supportsPolls, model.conversation.type.allowsPolls {
            items.append(.divider)
            items.append(.action("Poll…", systemImage: "chart.bar.doc.horizontal") { isShowingNewPoll = true })
        }
        if model.canCreateThread {
            items.append(.divider)
            items.append(.action("New Thread", systemImage: "bubble.left.and.bubble.right") {
                model.beginNewThread()
                isThreadTitleFocused = true
            })
        }
        let isEmpty = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let translator {
            items.append(.divider)
            items.append(translateMenu(translator, isEnabled: !isEmpty && draftTranslation?.isWorking != true))
        }
        // Proofread or rewrite what's in the field — Apple Intelligence, on this Mac.
        // Right-clicking the field has it too.
        items.append(.action("Writing Tools", systemImage: "apple.writing.tools", isEnabled: !isEmpty) {
            isFocused = true
            Task { @MainActor in
                NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: nil, from: nil)
            }
        })
        if model.canSchedule, model.editing == nil {
            items.append(.divider)
            // Straight to the capsule in the field; the quick times are in there.
            items.append(.action("Send Later", systemImage: "clock") { model.beginSendLater() })
        }
        return items
    }

    /// The + menu's Translate: the languages, the one used here last time first.
    private func translateMenu(_ translator: MessageTranslator, isEnabled: Bool) -> PopUpMenuItem {
        let recent = translator.outgoingLanguage(for: model.token)
        var languages: [PopUpMenuItem] = []
        if let recent {
            languages.append(.action(MessageTranslator.name(of: recent)) { translateDraft(into: recent, with: translator) })
            languages.append(.divider)
        }
        for language in translationLanguages where language.minimalIdentifier != recent?.minimalIdentifier {
            languages.append(.action(MessageTranslator.name(of: language)) { translateDraft(into: language, with: translator) })
        }
        return .submenu(hasSelection ? "Translate Selection" : "Translate", systemImage: "translate", isEnabled: isEnabled, languages)
    }

    /// Words selected in the field, inside what's there now.
    private var hasSelection: Bool {
        selection.length > 0 && NSMaxRange(selection) <= (model.draftText as NSString).length
    }

    /// Translates what's selected, or else the whole draft, and puts the translation in its
    /// place — to read over before sending. Show Original puts back the draft as it was.
    private func translateDraft(into language: Locale.Language, with translator: MessageTranslator) {
        let original = model.draftText
        let range = hasSelection ? selection : NSRange(location: 0, length: (original as NSString).length)
        let part = (original as NSString).substring(with: range)
        guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translator.setOutgoingLanguage(language, for: model.token)
        let name = MessageTranslator.name(of: language)
        draftTranslation = DraftTranslation(language: name, state: .working)
        Task {
            let result = await translator.translateOutgoing(part, to: language)
            // Typed on meanwhile: that wins.
            guard model.draftText == original else {
                draftTranslation = nil
                return
            }
            switch result {
            case .translated(let text):
                // Kept from the first translation on, so Show Original goes all the way back.
                if untranslated == nil { untranslated = original }
                // Whatever spacing was around the selection stays around the translation.
                let leading = part.prefix { $0.isWhitespace }
                let trailing = String(part.reversed().prefix { $0.isWhitespace }.reversed())
                model.draftText = (original as NSString).replacingCharacters(in: range, with: leading + text + trailing)
                draftTranslation = DraftTranslation(language: name, state: .translated)
            case .sameLanguage:
                draftTranslation = DraftTranslation(language: name, state: .problem("This is already in \(name)."))
            case .failed(let reason):
                draftTranslation = DraftTranslation(language: name, state: .problem(reason))
            }
        }
    }

    private func showOriginal() {
        if let untranslated { model.draftText = untranslated }
        untranslated = nil
        draftTranslation = nil
    }

    /// Text, character count and send, all inside one glass capsule — the field is a
    /// single control rather than a row of parts spread across the window.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A new thread's title, as the first line of the field — like the subject line
            // Messages can show. Return moves on to the message itself.
            if model.newThreadTitle != nil {
                ThreadTitleField(
                    title: Binding(get: { model.newThreadTitle ?? "" }, set: { model.newThreadTitle = $0 }),
                    isFocused: $isThreadTitleFocused,
                    onSubmit: { isFocused = true },
                    onCancel: {
                        model.cancelNewThread()
                        isFocused = true
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let draftTranslation {
                DraftTranslationPill(
                    translation: draftTranslation,
                    canShowOriginal: untranslated != nil,
                    onShowOriginal: showOriginal,
                    onDismiss: { self.draftTranslation = nil }
                )
                .padding(.top, 2)
                .padding(.bottom, 8)
                .padding(.leading, -5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // Send Later sits inside the field, above the words it will send — as in Messages.
            // The room under it keeps it clear of the send button's circle.
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
                onSubmit: submit,
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
                onGenmoji: { image, description in
                    guard model.attachments.canAttach else { return }
                    model.attachments.enqueuePastedImage(image, named: description.isEmpty ? "Genmoji" : description)
                },
                onSelectionChange: { selection = $0 }
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

                    Button(action: submit) {
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
        .animation(.smooth(duration: 0.2), value: model.newThreadTitle != nil)
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
        if model.editing != nil { return "Edit message" }
        if model.newThreadTitle != nil { return "First message in the thread" }
        if let thread = model.openThread { return "Reply in \(thread.title.isEmpty ? "thread" : thread.title)" }
        return "Message \(model.conversation.displayName)"
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
        } else if model.newThreadTitle != nil {
            model.cancelNewThread()
        } else if model.openThread != nil {
            // Nothing left to cancel here: Esc leaves the thread, as the bar's Back does.
            model.closeThread()
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


/// The draft being translated from the + menu, or translated a moment ago.
struct DraftTranslation: Equatable {
    enum State: Equatable {
        case working
        case translated
        case problem(String)
    }

    let language: String
    let state: State

    var isWorking: Bool { state == .working }
}

/// Inside the field once the draft has been translated: into which language, and the way back
/// to what was written.
private struct DraftTranslationPill: View {
    let translation: DraftTranslation
    let canShowOriginal: Bool
    var onShowOriginal: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "translate")
                .foregroundStyle(.tint)
            switch translation.state {
            case .working:
                Text("Translating into \(translation.language)…")
            case .translated:
                Text("Translated into \(translation.language)")
            case .problem(let problem):
                Text(problem)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            if canShowOriginal, !translation.isWorking {
                Button("Show Original", action: onShowOriginal)
                    .buttonStyle(.link)
            }
            Spacer(minLength: 4)
            if !translation.isWorking {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Keep the translation, and close this")
                .accessibilityLabel("Close")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// Suggested replies, as capsules over the field — Apple Intelligence's, marked as such.
private struct SmartReplyChips: View {
    let replies: [String]
    var onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Suggested replies")
            ForEach(replies, id: \.self) { reply in
                Button { onPick(reply) } label: {
                    Text(reply)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Put “\(reply)” in the field")
            }
            Spacer(minLength: 0)
        }
    }
}
