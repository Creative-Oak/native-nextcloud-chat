import AppKit
import SwiftUI

/// The transcript.
///
/// Scrolling rules, which are most of what makes a chat client feel right:
/// - opening a conversation lands at the bottom, with no visible scroll animation
/// - new messages follow the bottom **only** when you were already at the bottom
/// - loading older messages never moves what you are reading
/// - the newest message being on screen is one of the conditions for marking things read
struct ChatView: View {
    @Bindable var model: ChatModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by the window so ⌘⇧K and Return-from-the-sidebar can move focus here.
    @Binding var composerFocused: Bool

    @State private var highlightedMessageID: Int?
    @State private var didInitialScroll = false

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(model: model)
            Divider()
            transcript
            if let error = model.lastError, error != .cancelled {
                InlineStatusBar(error: error, state: model.syncState)
            }
            Divider()
            ComposerView(model: model, isFocused: $composerFocused)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(model.conversation.displayName)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topLoader

                    ForEach(model.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }

                    // A little breathing room above the composer, and the anchor the
                    // "scroll to bottom" logic targets.
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomAnchor)
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: ScrollPositionMetrics.self) { geometry in
                ScrollPositionMetrics(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height),
                    distanceFromTop: geometry.contentOffset.y
                )
            } action: { _, metrics in
                // 40pt of slack: "at the bottom" should survive a stray trackpad nudge.
                let atBottom = metrics.distanceFromBottom < 40
                if model.isScrolledToLatest != atBottom { model.isScrolledToLatest = atBottom }

                if metrics.distanceFromTop < 200 {
                    Task { await model.loadOlder() }
                }
            }
            .onChange(of: model.rows.last?.id) { _, _ in
                guard model.isScrolledToLatest else { return }
                scrollToBottom(proxy, animated: didInitialScroll)
            }
            .onAppear {
                // Land at the bottom (or at the unread marker) without an animation, so
                // opening a conversation looks instantaneous rather than "scrolly".
                if let unread = model.rows.first(where: \.isUnreadSeparator)?.id {
                    proxy.scrollTo(unread, anchor: .center)
                } else {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                didInitialScroll = true
            }
            .onChange(of: highlightedMessageID) { _, newValue in
                guard let newValue, let row = model.rows.first(where: { $0.message?.messageID == newValue }) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(row.id, anchor: .center)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) { scrollToBottomButton }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row.kind {
        case .daySeparator(let day):
            DaySeparator(day: day)
        case .unreadSeparator:
            UnreadSeparator()
        case .message(let message, let group):
            MessageRow(
                message: message,
                group: group,
                content: model.content(for: message),
                isFromMe: model.isFromMe(message),
                capabilities: model.capabilities,
                onReply: { model.beginReply(to: $0); composerFocused = true },
                onEdit: { model.beginEdit($0); composerFocused = true },
                onDelete: { model.delete($0) },
                onReact: { emoji, message in model.toggleReaction(emoji, on: message) },
                onRetry: { model.retry($0) },
                onDiscard: { model.discard($0) },
                onShowParent: { highlightedMessageID = $0 }
            )
            .background(highlightedMessageID == message.messageID ? Color.accentColor.opacity(0.12) : .clear)
        }
    }

    @ViewBuilder
    private var topLoader: some View {
        if model.isLoadingOlder {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 10)
        } else if !model.canLoadOlder && !model.rows.isEmpty {
            Text("Beginning of the conversation")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var scrollToBottomButton: some View {
        if !model.isScrolledToLatest {
            Button {
                model.isScrolledToLatest = true
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(8)
                    .background(.regularMaterial, in: .circle)
                    .overlay { Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .padding(16)
            .help("Scroll to the newest message")
            .transition(.opacity)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private static let bottomAnchor = "chat-bottom-anchor"
}

private struct ScrollPositionMetrics: Equatable {
    var distanceFromBottom: CGFloat
    var distanceFromTop: CGFloat
}

/// "Today", "Yesterday", or the date — the way Messages does it.
private struct DaySeparator: View {
    let day: Date

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var label: String { RelativeTimestamp.daySeparator(day) }
}

private struct UnreadSeparator: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
            Text("New messages")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Errors live here rather than in modal alerts: a chat client that interrupts you with a
/// dialog every time the network hiccups is unusable.
private struct InlineStatusBar: View {
    let error: TalkError
    let state: ChatSyncState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(error.userMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private var symbol: String {
        switch state {
        case .offline: "wifi.slash"
        case .reconnecting: "arrow.triangle.2.circlepath"
        default: "exclamationmark.circle"
        }
    }
}

/// The conversation title bar: who you're talking to, and the state of the connection.
private struct ChatHeaderView: View {
    @Bindable var model: ChatModel

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(conversation: model.conversation, size: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.conversation.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if model.syncState == .offline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if case .reconnecting = model.syncState {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var subtitle: String? {
        let conversation = model.conversation
        if let status = conversation.userStatus, let message = status.message, !message.isEmpty {
            return [status.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if conversation.isNoteToSelf { return "Just for you" }
        if !conversation.description.isEmpty { return conversation.description }
        if conversation.hasCall { return "Call in progress" }
        return nil
    }
}
