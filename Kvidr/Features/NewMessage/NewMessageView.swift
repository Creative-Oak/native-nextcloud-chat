import SwiftUI

/// The detail pane while a draft is selected: who it is to, above; what to say, below.
///
/// Deliberately not `ChatView`. There is no conversation to show a transcript of, and the
/// space between the two fields is where the people you are searching for appear.
struct NewMessageView: View {
    @Bindable var draft: ConversationDraft
    var onSent: (Conversation) -> Void

    @FocusState private var focus: Field?
    private enum Field { case recipients, message }

    var body: some View {
        VStack(spacing: 0) {
            toField

            if !draft.results.isEmpty {
                results
            } else {
                Spacer(minLength: 0)
                if let error = draft.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding()
                }
                Spacer(minLength: 0)
            }

            composer
        }
        .navigationTitle(draft.title)
        .onAppear { focus = .recipients }
    }

    // MARK: - To

    /// The band across the top, floating as Messages' does rather than sitting in a header
    /// with a rule under it: glass, the full width, and the toggle riding at its trailing
    /// edge the way the composer's buttons ride at its.
    private var toField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(draft.recipients) { recipient in
                    Button { draft.remove(recipient) } label: {
                        HStack(spacing: 4) {
                            Text(recipient.label).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .glass(.chip)
                }

                TextField("", text: $draft.search, prompt: Text(draft.recipients.isEmpty ? "Name, group or team" : ""))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($focus, equals: .recipients)
                    // Backspace on an empty field takes the last chip back, as in Messages.
                    .onKeyPress(.delete) {
                        guard draft.search.isEmpty, !draft.recipients.isEmpty else { return .ignored }
                        draft.removeLastRecipient()
                        return .handled
                    }
            }

            if draft.isSearching { ProgressView().controlSize(.small) }

            // Public rather than private. A one-to-one cannot be public, so switching this on
            // makes even a single recipient an open conversation.
            //
            // A `Toggle` in `.button` style rather than a switch: it is still a toggle to
            // VoiceOver and to the keyboard, but it takes the app's own glass — a pill that
            // tints with the accent when it is on, like a reaction that includes you.
            Toggle(isOn: $draft.isOpen) {
                Label("Open", systemImage: "globe")
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .glass(draft.isOpen ? .selectedChip : .chip)
            .foregroundStyle(draft.isOpen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .help("Anyone on the server can find and join this conversation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var results: some View {
        List(draft.results) { entry in
            Button { draft.toggle(entry) } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.source.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.label).lineLimit(1)
                        if let subline = entry.subline, !subline.isEmpty {
                            Text(subline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    // MARK: - Message

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $draft.text, prompt: Text("Message"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focus, equals: .message)
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
