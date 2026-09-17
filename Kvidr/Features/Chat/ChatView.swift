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
    @Environment(AppModel.self) private var app
    @Environment(\.preferences) private var preferences
    /// Owned by the window so ⌘⇧K and Return-from-the-sidebar can move focus here.
    @Binding var composerFocused: Bool
    /// Keeps the frosted band over the header up whether or not the pointer is there —
    /// while the sidebar has given way to the inspector, as Messages does.
    var isHeaderAlwaysFrosted = false
    /// The conversation as the sidebar last synced it. `model.conversation` is the snapshot
    /// the conversation opened with, and a call starting or ending doesn't reach it.
    var liveConversation: Conversation?
    /// Reminders on this conversation's messages, and the way to set one.
    var reminders: ReminderStore?
    /// Reply Privately: opens the one-to-one with the author, with the message quoted.
    var onReplyPrivately: (Message) -> Void = { _ in }
    /// Forward…: asks where to, then sends it there.
    var onForward: (Message) -> Void = { _ in }
    /// Opens a conversation — the Show on the forwarded note.
    var onOpenConversation: (String) -> Void = { _ in }
    /// Opens the one-to-one with a user — an out-of-office's stand-in.
    var onMessageUser: (String) -> Void = { _ in }

    @State private var highlightedMessageID: Int?
    @State private var didInitialScroll = false
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var viewingAttachment: RichObject?
    /// One per conversation, so two cards for the same poll agree and fetch once.
    @State private var pollStore: PollStore?
    /// Suppresses per-row hover work while the transcript is moving.
    @State private var isScrolling = false
    /// The message whose reactions are floating above it, if any.
    @State private var tapbackMessageID: Int?
    @State private var tapbackBarSize: CGSize = .zero
    /// The toolbar's depth, from the top of the window — where the pointer counts as
    /// being over the header, and how far the frosted band reaches.
    @State private var toolbarDepth: CGFloat = 0
    @State private var isPointerOverHeader = false
    /// What you missed, when you ask for it. One per conversation.
    @State private var catchUp = CatchUpModel()

    /// The user's own Note to self conversation, where "Add to Notes" puts things.
    ///
    /// Read from the whole index rather than the sidebar's list: that one is filtered by
    /// whatever is typed in the search field and leaves the archive out, and notes to self
    /// are exactly the kind of conversation people archive and still use.
    private var noteToSelfToken: String? {
        guard model.capabilities.supportsNoteToSelf else { return nil }
        return app.conversationList?.index.allConversations.first { $0.isNoteToSelf }?.token
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .top) {
                    // The transient bar, one at a time, then the pinned message under it —
                    // a pin is standing information and shouldn't give way to a call.
                    VStack(spacing: 6) {
                        if let error = model.lastError, error != .cancelled {
                            InlineStatusBar(error: error, state: model.syncState)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if let messageID = model.unreachableMessageID {
                            UnreachableMessageBar(
                                onOpenInBrowser: {
                                    NSWorkspace.shared.open(model.webURL(forMessage: messageID))
                                    model.dismissUnreachableMessage()
                                },
                                onDismiss: { model.dismissUnreachableMessage() }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else if model.isRevealing {
                            RevealingBar()
                                .transition(.opacity)
                        } else if let target = model.forwardedTo {
                            ForwardedBar(name: target.displayName) {
                                model.forwardedTo = nil
                                onOpenConversation(target.token)
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else if let live = liveConversation, live.hasCall {
                            CallInProgressBar(conversation: live) {
                                NSWorkspace.shared.open(model.webURL)
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let absence = model.absence {
                            AbsenceBar(
                                name: model.conversation.displayName,
                                absence: absence,
                                onMessageReplacement: absence.replacementUserID.map { id in { onMessageUser(id) } },
                                onDismiss: { model.absence = nil }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let pin = model.visiblePin {
                            PinnedBar(model: model, pin: pin) { messageID in
                                Task { await model.reveal(messageID: messageID) }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, ConversationHeader.depthBelowToolbar + 10)
                    .padding(.horizontal, 16)
                }
                .animation(.smooth(duration: 0.25), value: model.lastError)
                .animation(.smooth(duration: 0.25), value: model.unreachableMessageID)
                .animation(.smooth(duration: 0.25), value: model.isRevealing)
                .animation(.smooth(duration: 0.25), value: liveConversation?.hasCall)
                .animation(.smooth(duration: 0.25), value: model.visiblePin?.id)
                .animation(.smooth(duration: 0.25), value: model.forwardedTo?.token)
                .animation(.smooth(duration: 0.25), value: model.absence)
                // An inset rather than another row in the stack: the composer floats over
                // the transcript the way Messages' does, and the scroll view still knows
                // not to hide the newest message behind it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ComposerView(model: model, isFocused: $composerFocused)
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Settings decide whether the chips appear at all, and where a reminder armed in
        // the composer goes once the message it belongs to exists.
        .task(id: model.token) { configureSuggestions() }
        // Where the pointer counts as over the header — the toolbar and the name
        // capsule under it — which is what brings the frosted band up; the band itself
        // is the transcript's top scroll edge, hardened.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.top
        } action: { depth in
            toolbarDepth = depth
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                isPointerOverHeader = point.y < Self.frostDepth(below: toolbarDepth)
            case .ended:
                isPointerOverHeader = false
            }
        }
        // Their face, up in the toolbar band, over the name capsule that hangs below
        // it. Drawn here rather than as a toolbar item so it is centred on the
        // transcript — a toolbar item centres on the whole column, panel included. The
        // band takes the clicks; the capsule under it is the control.
        .overlay(alignment: .top) {
            AvatarView(conversation: model.conversation, size: ConversationHeader.avatarSize)
                .padding(.top, ConversationHeader.avatarTopInset)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle(model.conversation.displayName)
        .onChange(of: liveConversation?.hiddenPinnedID) { _, id in
            if let id { model.hiddenPinChangedElsewhere(id) }
        }
        // Name, picture and permissions follow the sidebar as it syncs.
        .onChange(of: liveConversation) { _, fresh in
            if let fresh { model.conversationChanged(fresh) }
        }
        // Drop anywhere in the conversation, not just on the composer — that is where
        // people aim, and aiming at a 30pt field with a file in hand is a chore.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.attachments.canAttach, model.conversation.canPostMessages else { return false }
            // `URL.self` matches `public.url` as well as `public.file-url`, so a hyperlink
            // dragged out of the transcript or a browser arrives here indistinguishable
            // from a dragged document. The queue refuses those; saying so here as well
            // means the drag is reported as declined rather than silently swallowed.
            //
            // Only what the URL itself says, though: this runs on the main thread and must
            // answer now, and asking the file system anything about a file on a wedged
            // network mount doesn't return. A folder is spelled with a trailing slash, so it
            // is still declined here; anything subtler (a pipe, a device) is refused by the
            // queue, which asks off the main thread and under a deadline.
            let files = urls.filter { $0.isLocalFile && !$0.hasDirectoryPath }
            guard !files.isEmpty else { return false }
            model.attachments.enqueue(urls: files)
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
                    .padding(.top, ConversationHeader.depthBelowToolbar + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: model.isSearching)
        .environment(\.openAttachment) { object in
            withAnimation(.smooth(duration: 0.2)) { viewingAttachment = object }
        }
        .environment(\.pollStore, pollStore)
        .task(id: model.conversation.token) {
            let store = PollStore(session: model.session, token: model.conversation.token)
            store.isModerator = model.conversation.isModerator
            pollStore = store
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

                    // Waiting to be sent: after everything that has been, as in Messages.
                    ForEach(model.scheduled) { message in
                        ScheduledMessageRow(model: model, message: message)
                            .id("scheduled-\(message.id)")
                    }

                    if !model.typists.isEmpty {
                        TypingIndicatorRow(typists: model.typists, conversation: model.conversation)
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
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
            // The name capsule hangs just below the toolbar. As a bar rather than an
            // overlay, the scroll edge fade extends down behind it and the newest
            // message never lands underneath it. Soft, explicitly: left to itself the
            // toolbar comes up with the opaque, hairlined kind at launch and only
            // switches to the fade after the first scroll.
            .safeAreaBar(edge: .top, spacing: 0) {
                ConversationHeader(conversation: model.conversation)
            }
            // Messages' frosted band: the strip over the transcript — the toolbar and
            // the name capsule — is the soft edge fade until the pointer is up there,
            // then the hard edge: the system's own frosted pocket, its material the
            // sidebar's, a hairline at its foot, and the messages behind read through
            // frost. Drawn by the system rather than by hand, so it is the same grey as
            // the sidebar wherever the window sits. It stays hard while the sidebar is
            // away for the inspector.
            .scrollEdgeEffectStyle(isPointerOverHeader || isHeaderAlwaysFrosted ? .hard : .soft, for: .top)
            // Deliberately two Bools rather than two distances. A raw offset changes on
            // every frame of a scroll, so an Equatable built from offsets is never equal
            // to its predecessor and this action runs every frame — which is both the
            // "tried to update multiple times per frame" warning and a good part of the
            // jank. Thresholds only change when they are actually crossed.
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                // Measured from the visible rect, which knows about the insets. The
                // transcript runs under the toolbar, the header and the composer, and a
                // sum of offset and container size counts the top inset as distance
                // still to scroll — so the view believed it was never quite at the
                // bottom, and the scroll-to-bottom button never went away.
                let fromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
                return ScrollEdges(
                    // 40pt of slack: "at the bottom" should survive a stray trackpad nudge.
                    isAtBottom: fromBottom < 40,
                    // Start fetching before the user reaches the top, so history is
                    // usually already there by the time they arrive.
                    isNearTop: geometry.visibleRect.minY < 240
                )
            } action: { _, edges in
                if model.isScrolledToLatest != edges.isAtBottom {
                    model.isScrolledToLatest = edges.isAtBottom
                }
                guard didInitialScroll, edges.isNearTop,
                      model.canLoadOlder, !model.isLoadingOlder
                else { return }
                Task { await loadOlderKeepingPosition(proxy) }
            }
            // The transcript changes width when the inspector slides in or out and the
            // window is resized. The rows re-wrap and the content grows or shrinks, but
            // the scroll position is kept from the top, so a transcript that was at the
            // bottom drifts off it a little more with every frame of the slide. Re-pinned
            // on each width change while it was at the bottom — instantly, since the
            // slide itself is the animation.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.width
            } action: { _, _ in
                guard didInitialScroll, model.isScrolledToLatest else { return }
                scrollToBottom(proxy, animated: false)
            }
            // Rows sliding under a stationary pointer fire onHover continuously, which
            // flickers the action strip and re-lays out every row it touches. Nothing
            // hovers while the transcript is moving.
            .onScrollPhaseChange { _, phase in
                let scrolling = phase != .idle
                if isScrolling != scrolling { isScrolling = scrolling }
                // Scrolling away is as good as clicking elsewhere.
                if scrolling, tapbackMessageID != nil { dismissTapback() }
            }
            .environment(\.isTranscriptScrolling, isScrolling)
            // The bubble comes into view if the transcript was at the bottom, as a message would.
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.typists.isEmpty)
            .onChange(of: model.typists.isEmpty) { _, isEmpty in
                guard didInitialScroll, !isEmpty, model.isScrolledToLatest else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: model.rows.last?.id) { _, _ in
                // `didInitialScroll` gates this as well as the initial positioning: when
                // the first rows arrive both this and the isEmpty handler below fire in
                // the same frame, and both scroll. Two scrollTo calls in one frame is
                // the "onChange action tried to update multiple times per frame"
                // warning. The first frame belongs to positionInitially.
                guard didInitialScroll, model.isScrolledToLatest else { return }
                scrollToBottom(proxy, animated: true)
            }
            // The first rows arrive from the cache *after* the view appears, so the initial
            // positioning has to wait for them rather than happening in onAppear. Counted
            // rather than `isEmpty`: emptiness is a Bool, so it changes once and never
            // again, and if that one attempt came too early there was nothing left to try.
            .onChange(of: model.rows.count) { _, _ in positionInitially(proxy) }
            .onAppear { positionInitially(proxy) }
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
            .overlayPreferenceValue(TapbackAnchorKey.self) { anchors in
                tapbackOverlay(anchors)
            }
        }
    }

    /// How far the header reaches from the top of the window: the toolbar, and the name
    /// capsule hanging under it.
    private static func frostDepth(below toolbarDepth: CGFloat) -> CGFloat {
        toolbarDepth + ConversationHeader.depthBelowToolbar
    }

    /// The floating reactions over the message that was pressed, with the rest of the
    /// transcript dimmed a shade behind them. A click anywhere else puts them away.
    @ViewBuilder
    private func tapbackOverlay(_ anchors: [Int: TapbackAnchor]) -> some View {
        if let id = tapbackMessageID,
           let anchor = anchors[id],
           let row = model.rows.first(where: { $0.message?.messageID == id }),
           let message = row.message {
            GeometryReader { geometry in
                let bubble = geometry[anchor.bounds]
                let size = geometry.size
                // Above the bubble, aligned to its outer edge — unless that would run
                // off the top, in which case below it.
                let x = anchor.isFromMe
                    ? min(max(bubble.maxX - tapbackBarSize.width, 8), size.width - tapbackBarSize.width - 8)
                    : min(max(bubble.minX, 8), size.width - tapbackBarSize.width - 8)
                let above = bubble.minY - tapbackBarSize.height - 6
                let y = above >= 8 ? above : bubble.maxY + 6

                ZStack(alignment: .topLeading) {
                    Color.primary.opacity(0.06)
                        .contentShape(.rect)
                        .onTapGesture { dismissTapback() }

                    TapbackBar(
                        message: message,
                        onReact: { model.toggleReaction($0, on: message) },
                        onDone: { dismissTapback() }
                    )
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tapbackBarSize = $0 }
                    .offset(x: x, y: y)
                    .transition(.scale(scale: 0.6, anchor: anchor.isFromMe ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
                }
                .transition(.opacity)
            }
            .ignoresSafeArea()
        }
    }

    /// What Settings allows, and where a reminder armed in the composer goes once the
    /// message it belongs to exists.
    private func configureSuggestions() {
        model.showsSuggestions = preferences?.showsMessageSuggestions ?? true
        catchUp.intelligence = app.intelligence
        catchUp.isEnabled = preferences?.offersCatchUp ?? true
        catchUp.prepare(for: model)
        model.onArmedReminder = { [reminders] message, date in
            reminders?.remind(about: message, at: date)
        }
    }

    private func activate(_ suggestion: MessageSuggestion, on message: Message) {
        model.activate(suggestion, on: message, reminders: reminders, noteToSelfToken: noteToSelfToken)
    }

    private func dismissTapback() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { tapbackMessageID = nil }
    }

    /// Opening a conversation lands on the unread marker if there is one, otherwise at the
    /// bottom — and without animating, so it reads as "already there" rather than as a scroll.
    ///
    /// The scroll is deferred by one turn on purpose. The update that publishes the first
    /// rows has not laid them out yet, and `scrollTo` for an id the scroll view does not
    /// hold is dropped without complaint — which left the transcript at the offset it had
    /// while the content was empty, the top, with `didInitialScroll` already spent.
    private func positionInitially(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, !model.rows.isEmpty else { return }
        didInitialScroll = true

        let unread = model.rows.first(where: \.isUnreadSeparator)?.id
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let unread {
                    proxy.scrollTo(unread, anchor: .center)
                } else {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row.kind {
        case .daySeparator(let day):
            DaySeparator(day: day)
        case .unreadSeparator:
            UnreadSeparatorRow(
                state: catchUp.state,
                unreadCount: catchUp.canOffer(for: model) ? model.unreadForCatchUp.count : nil,
                onCatchUp: { catchUp.summarise(model) },
                onDismiss: { catchUp.dismiss() }
            )
        case .message(let message, let group):
            MessageRow(
                message: message,
                group: group,
                content: model.content(for: message),
                isFromMe: model.isFromMe(message),
                capabilities: model.capabilities,
                onReply: { model.beginReply(to: $0); composerFocused = true },
                onReplyPrivately: model.canReplyPrivately(to: message) ? onReplyPrivately : nil,
                onForward: ForwardPlan.plan(for: message) != nil ? onForward : nil,
                reminder: reminders?.reminder(token: message.token, messageID: message.messageID),
                onRemind: reminders?.canRemind == true ? { date in reminders?.remind(about: message, at: date) } : nil,
                onRemoveReminder: { reminders?.remove($0) },
                pin: model.pin(for: message.messageID),
                onPin: model.canPin ? { duration in model.pin(message, for: duration) } : nil,
                onUnpin: { model.unpin(messageID: $0) },
                onEdit: { model.beginEdit($0); composerFocused = true },
                onDelete: { model.delete($0) },
                onReact: { emoji, message in model.toggleReaction(emoji, on: message) },
                onRetry: { model.retry($0) },
                onDiscard: { model.discard($0) },
                onShowParent: { highlightedMessageID = $0 },
                suggestions: model.suggestions(for: message),
                usedSuggestions: model.usedSuggestionKeys(for: message),
                onSuggestion: { activate($0, on: message) },
                isTapbackTarget: tapbackMessageID == message.messageID,
                onShowTapback: { pressed in
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { tapbackMessageID = pressed.messageID }
                }
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
            .accessibilityLabel("Scroll to Newest Message")
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
            // Explicitly without animation: called from inside another animation's
            // frames, it would otherwise inherit that animation and lag behind it.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    private static let bottomAnchor = "chat-bottom-anchor"
}

private struct ScrollEdges: Equatable {
    var isAtBottom: Bool
    var isNearTop: Bool
}

private struct IsTranscriptScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the transcript is being scrolled. Rows use it to stand down.
    var isTranscriptScrolling: Bool {
        get { self[IsTranscriptScrollingKey.self] }
        set { self[IsTranscriptScrollingKey.self] = newValue }
    }
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
