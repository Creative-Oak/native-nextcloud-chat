import SwiftUI

/// ⌘K — type a few letters, hit Return, you're in the conversation.
///
/// The keyboard path that makes the app usable without the mouse: it never steals focus
/// from the composer unless asked, closes on Escape, and puts you straight back where you
/// were if you cancel.
struct QuickSwitcher: View {
    let conversations: [Conversation]
    var onPick: (Conversation) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private var matches: [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let pool = trimmed.isEmpty
            ? conversations
            : conversations.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
        return Array(pool.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Go to conversation", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($isFieldFocused)
                .onSubmit(pick)
                .onChange(of: query) { _, _ in highlighted = 0 }

            if !matches.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.token) { index, conversation in
                                row(conversation, isHighlighted: index == highlighted)
                                    .id(conversation.token)
                                    .contentShape(.rect)
                                    .onTapGesture {
                                        highlighted = index
                                        pick()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: highlighted) { _, index in
                        guard matches.indices.contains(index) else { return }
                        proxy.scrollTo(matches[index].token)
                    }
                }
            }
        }
        .frame(width: 420)
        .glass(.panel, cornerRadius: 14)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { isFieldFocused = true }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    private func row(_ conversation: Conversation, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarView(conversation: conversation, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.displayName)
                    .lineLimit(1)
                Text(ConversationPreview.text(for: conversation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if conversation.hasUnread {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + offset, 0), matches.count - 1)
        return .handled
    }

    private func pick() {
        guard matches.indices.contains(highlighted) else { return }
        onPick(matches[highlighted])
    }
}
