import SwiftUI

/// Where a message is being forwarded: a search field over the conversations, most recent
/// first, one click to send it there.
struct ForwardSheet: View {
    let message: Message
    let conversations: [Conversation]
    var onForward: (Conversation) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward Message")
                .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { if let first = matches.first { onForward(first) } }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glass(.field, cornerRadius: 15)

            List(matches) { conversation in
                Button { onForward(conversation) } label: {
                    HStack(spacing: 10) {
                        AvatarView(conversation: conversation, size: 28)
                        Text(conversation.displayName)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(height: 300)

            HStack {
                Text("Mentions are sent as plain names, so nobody is notified again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isSearchFocused = true }
    }

    private var matches: [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let usable = conversations.filter { $0.canPostMessages && $0.token != message.token }
        guard !trimmed.isEmpty else { return usable }
        return usable.filter { $0.displayName.localizedStandardContains(trimmed) }
    }
}

/// Said at the top of the conversation after forwarding: where it went, and the way there.
struct ForwardedBar: View {
    let name: String
    var onShow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(.secondary)
            Text("Forwarded to \(name)")
                .font(.callout)
                .lineLimit(1)
            Button("Show", action: onShow)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.panel, cornerRadius: 10)
    }
}
