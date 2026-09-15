import SwiftUI

/// The detail pane while a draft is selected: who it is to, above; what to say, below.
///
/// Deliberately not `ChatView`. There is no conversation to show a transcript of, and the
/// space between the two fields is where the people you are searching for appear.
struct NewMessageView: View {
    @Bindable var draft: ConversationDraft
    /// Owned by the window, because the To: field it drives lives in the toolbar.
    @FocusState.Binding var recipientsFocused: Bool
    var onSent: (Conversation) -> Void

    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
        // Hanging from the top rather than filling the pane: the matches belong under the
        // band they came from, the way Messages drops them out of the To: field.
        .overlay(alignment: .top) { suggestions }
        .navigationTitle(draft.title)
        .onAppear { recipientsFocused = true }
    }

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
                    // The first match reads as the one Return would take, as it does in
                    // Messages, rather than every row looking equally likely.
                    .background {
                        if index == 0 {
                            // 16 less the 6 it is inset by: a rounded rectangle inside
                            // another wants the difference, or the two curves sit at
                            // different centres and the eye reads a double border.
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .padding(.horizontal, 6)
                        }
                    }
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
        HStack(alignment: .bottom, spacing: 8) {
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
