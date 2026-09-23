import SwiftUI

/// Every unread conversation in a few lines, in the messages column: what happened, what's
/// asked of you, the dates — the ones that need you first. A click opens the conversation.
struct CatchUpPage: View {
    let model: CatchUpModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if model.entries.isEmpty, !model.isRunning {
                ContentUnavailableView {
                    Label("All Caught Up", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing unread. Conversations with new messages show here, a few lines each.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        ForEach(model.entries) { entry in
                            CatchUpCard(entry: entry) { app.selectedToken = entry.conversation.token }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Catch Up")
        .task {
            // Fresh each time it's opened, unless it's still at it.
            if !model.isRunning { model.run(over: app.conversationList?.index.allConversations ?? []) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Catch Up")
                    .font(.system(size: 22, weight: .bold))
                Label("Written on this Mac by Apple Intelligence. Nothing is marked as read.", systemImage: "apple.intelligence")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh") { model.run(over: app.conversationList?.index.allConversations ?? []) }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct CatchUpCard: View {
    let entry: CatchUpModel.Entry
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(conversation: entry.conversation, size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.conversation.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if entry.conversation.unreadMention {
                            Text("@").font(.system(size: 12, weight: .bold)).foregroundStyle(.tint)
                        }
                        Text("\(entry.conversation.unreadMessages) unread")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if case .done(let digest) = entry.state, digest.urgency == 2 {
                            Text("Needs an answer")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange, in: .capsule)
                        }
                    }
                    content
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(entry.conversation.displayName)")
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .waiting:
            Text("Waiting…").font(.system(size: 12)).foregroundStyle(.tertiary)
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
        case .done(let digest):
            Text(digest.gist)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !digest.forYou.isEmpty {
                lines("For you", symbol: "questionmark.bubble", digest.forYou)
            }
            if !digest.dates.isEmpty {
                lines("Dates", symbol: "calendar", digest.dates)
            }
        }
    }

    private func lines(_ title: String, symbol: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The sidebar's way in, over the conversations while several are unread.
struct CatchUpSidebarRow: View {
    let count: Int

    var body: some View {
        SidebarShortcutRow(title: "Catch Up", systemImage: "apple.intelligence", iconStyle: AnyShapeStyle(.tint), count: count)
            .accessibilityLabel("Catch Up, \(count) unread conversations")
    }
}
