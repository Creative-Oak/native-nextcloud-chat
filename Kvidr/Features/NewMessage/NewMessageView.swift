import SwiftUI

/// The detail pane while a draft is selected: who it is to, above; what to say, below.
///
/// Deliberately not `ChatView`. There is no conversation to show a transcript of, and the
/// space between the two fields is where the people you are searching for appear.
struct NewMessageView: View {
    @Bindable var draft: ConversationDraft
    /// Owned by the window, because the To: band sits above this view's own content.
    @FocusState.Binding var recipientsFocused: Bool
    /// The strip the toolbar would have occupied, measured by the window.
    var titleBarHeight: CGFloat
    var onSent: (Conversation) -> Void

    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // On the traffic lights' line, not under it. The pane has taken the strip the
            // toolbar reserves — the compose and search buttons stand down while a draft is
            // open, so nothing else wants it — and the band is centred in it.
            //
            // The same inset on every side, and derived rather than chosen: what centres the
            // band vertically is the strip's spare height halved, so the sides take that too
            // and the band sits as far from the window's edges as from its top. Two numbers
            // picked separately is what made it look inset more at the sides than above.
            RecipientBand(draft: draft, isFocused: $recipientsFocused)
                .padding(.horizontal, bandInset)
                .padding(.vertical, bandInset)

            Spacer(minLength: 0)

            if let error = draft.error, draft.results.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
            }

            Spacer(minLength: 0)
            composer
        }
        // Hanging from the band rather than filling the pane: the matches belong under the
        // field they came from, the way Messages drops them out of the To: field.
        // Under where you are typing rather than centred over the band: the matches belong
        // to the field they came from. Leading-aligned, inset past the "To:" label, which is
        // where the cursor sits before any chips are in the way.
        .overlay(alignment: .topLeading) {
            suggestions
                .padding(.top, titleBarHeight + 4)
                .padding(.leading, bandInset + Self.toLabelWidth)
        }
        .navigationTitle(draft.title)
        // Keyed on the request rather than on appearing, so a second ⌘N puts the cursor back
        // in the To: field instead of only selecting the row that is already selected.
        //
        // And on the turn after, not this one: a field that is still being built is not in
        // the responder chain yet, and focus set at it there goes nowhere.
        .task(id: draft.focusRequest) {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            recipientsFocused = true
        }
    }

    /// The band's margin, which is whatever centring it in the toolbar's strip asks for.
    private var bandInset: CGFloat {
        max(6, (titleBarHeight - GlassMetrics.control) / 2)
    }

    /// How far into the band the typing starts: its own leading padding, plus "To:" and the
    /// gap after it. Enough to put the matches under the cursor rather than under the label.
    private static let toLabelWidth: CGFloat = 44

    @ViewBuilder
    private var suggestions: some View {
        if !draft.results.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(draft.results.prefix(6).enumerated()), id: \.element.id) { index, entry in
                    ContactRow(entry: entry, isChosen: draft.isRecipient(entry)) {
                        draft.toggle(entry)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    // The highlighted match is the one Return takes, and the arrow keys move
                    // it — so this follows the keyboard rather than always sitting on the top
                    // row. The pointer moves it too, so hovering and pressing Return agree.
                    .background {
                        if index == draft.highlighted {
                            // 16 less the 6 it is inset by: a rounded rectangle inside
                            // another wants the difference, or the two curves sit at
                            // different centres and the eye reads a double border.
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .padding(.horizontal, 6)
                        }
                    }
                    .onHover { if $0 { draft.highlight(index) } }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: 420)
            .glass(.panel, cornerRadius: 16)
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Message

    private var composer: some View {
        VStack(spacing: 0) {
            AttachmentTray(queue: draft.attachments)
            field
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if draft.attachments.canAttach {
                // A draft has no conversation yet, and does not need one: uploading is
                // WebDAV, and only sharing needs somewhere to share into. The queue takes
                // its token when the conversation is made.
                AttachmentMenu(queue: draft.attachments, destination: draft.title)
            }

            TextField("", text: $draft.text, prompt: Text("Message"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isMessageFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: GlassMetrics.control)
                .glass(.field, cornerRadius: GlassMetrics.control / 2)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(!draft.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        guard draft.canSend else { return }
        Task {
            if let conversation = await draft.send() { onSent(conversation) }
        }
    }
}
