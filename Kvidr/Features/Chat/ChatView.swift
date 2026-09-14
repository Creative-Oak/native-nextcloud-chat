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
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var viewingAttachment: RichObject?

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(model: model)
            Divider()
            transcript
                .overlay(alignment: .top) {
                    if let error = model.lastError, error != .cancelled {
                        InlineStatusBar(error: error, state: model.syncState)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if let messageID = model.unreachableMessageID {
                        UnreachableMessageBar(
                            onOpenInBrowser: {
                                NSWorkspace.shared.open(model.webURL(forMessage: messageID))
                                model.dismissUnreachableMessage()
                            },
                            onDismiss: { model.dismissUnreachableMessage() }
                        )
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if model.isRevealing {
                        RevealingBar()
                            .padding(.top, 10)
                            .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.25), value: model.lastError)
                .animation(.smooth(duration: 0.25), value: model.unreachableMessageID)
                .animation(.smooth(duration: 0.25), value: model.isRevealing)
            Divider()
            ComposerView(model: model, isFocused: $composerFocused)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(model.conversation.displayName)
        // Drop anywhere in the conversation, not just on the composer — that is where
        // people aim, and aiming at a 30pt field with a file in hand is a chore.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.attachments.canAttach, model.conversation.canPostMessages else { return false }
            model.attachments.enqueue(urls: urls, replyTo: model.replyingTo?.messageID)
            model.cancelReply()
            return true
        } isTargeted: { targeted in
            withAnimation(.smooth(duration: 0.15)) { model.attachments.setDropTargeted(targeted) }
        }
        .overlay {
            if model.attachments.isDropTargeted && model.conversation.canPostMessages {
                DropTargetOverlay()
            }
        }
        .overlay {
            if let viewingAttachment {
                AttachmentViewer(object: viewingAttachment) {
                    withAnimation(.smooth(duration: 0.2)) { self.viewingAttachment = nil }
                }
            }
        }
        .overlay(alignment: .top) {
            if model.isSearching {
                ChatSearchBar(model: model)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: model.isSearching)
        .environment(\.openAttachment) { object in
            withAnimation(.smooth(duration: 0.2)) { viewingAttachment = object }
        }
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

                // Start fetching before the user reaches the top, so history is usually
                // already there by the time they arrive.
                guard didInitialScroll, metrics.distanceFromTop < 240,
                      model.canLoadOlder, !model.isLoadingOlder
                else { return }
                Task { await loadOlderKeepingPosition(proxy) }
            }
            .onChange(of: model.rows.last?.id) { _, _ in
                guard model.isScrolledToLatest else { return }
                scrollToBottom(proxy, animated: didInitialScroll)
            }
            // The first rows arrive from the cache *after* the view appears, so the initial
            // positioning has to wait for them rather than happening in onAppear.
            .onChange(of: model.rows.isEmpty) { _, isEmpty in
                if !isEmpty { positionInitially(proxy) }
            }
            .onAppear {
                if !model.rows.isEmpty { positionInitially(proxy) }
            }
            // The inspector (and anything else outside this view) asks for a message by
            // setting `highlightRequest`; the scrolling itself stays here.
            .onChange(of: model.highlightRequest) { _, requested in
                guard let requested else { return }
                highlightedMessageID = requested
                model.highlightRequest = nil
            }
            .onChange(of: highlightedMessageID) { _, newValue in
                guard let newValue, let row = model.rows.first(where: { $0.message?.messageID == newValue }) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(row.id, anchor: .center)
                }
                // The highlight is a "here it is" flash, not a selection — clear it so the
                // message doesn't stay tinted for the rest of the session.
                highlightClearTask?.cancel()
                highlightClearTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                        highlightedMessageID = nil
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) { scrollToBottomButton(proxy) }
        }
    }

    /// Opening a conversation lands on the unread marker if there is one, otherwise at the
    /// bottom — and without animating, so it reads as "already there" rather than as a scroll.
    private func positionInitially(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll else { return }
        didInitialScroll = true

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let unread = model.rows.first(where: \.isUnreadSeparator)?.id {
                proxy.scrollTo(unread, anchor: .center)
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
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
    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        if !model.isScrolledToLatest {
            Button {
                // Actually scroll — flipping the flag alone would just lie about where we are.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                model.isScrolledToLatest = true
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .padding(16)
            .help("Scroll to the newest message")
            .transition(.opacity)
        }
    }

    /// Loads older messages without moving what the user is reading.
    ///
    /// Prepending rows to a scroll view shifts everything below them down, which normally
    /// yanks the reader upward by exactly the height of what was just inserted. Pinning the
    /// row that was at the top before the fetch, and restoring it after, is what makes
    /// scrolling up feel like the content was always there.
    private func loadOlderKeepingPosition(_ proxy: ScrollViewProxy) async {
        let anchor = model.rows.first?.id
        await model.loadOlder()
        guard let anchor else { return }

        // One turn for SwiftUI to lay out the inserted rows before we re-anchor.
        await Task.yield()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor, anchor: .top)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(.floating, cornerRadius: 14)
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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

/// Shown while the transcript pages backwards towards a searched-for message.
private struct RevealingBar: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading earlier messages…")
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.panel, cornerRadius: 10)
    }
}

/// The search result was further back than the transcript will page to. Rather than
/// pretending, the web UI — which can jump straight to a message — is offered instead.
private struct UnreachableMessageBar: View {
    var onOpenInBrowser: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("That message is further back than this conversation has loaded.")
                .font(.callout)
            Button("Open in Nextcloud", action: onOpenInBrowser)
                .buttonStyle(.link)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.panel, cornerRadius: 10)
    }
}
