import AppKit
import SwiftUI

/// One message in the transcript.
///
/// Grouping decisions (whether to repeat the avatar and name, how much space to leave) are
/// made by ``MessageGroupContext`` and passed in, so this view never looks at its
/// neighbours — that is what keeps a 10 000-message conversation from re-rendering when
/// one message changes.
struct MessageRow: View {
    let message: Message
    let group: MessageGroupContext
    let content: MessageContent
    let isFromMe: Bool
    let capabilities: TalkCapabilities

    var onReply: (Message) -> Void
    /// Nil where the message can't be answered privately.
    var onReplyPrivately: ((Message) -> Void)?
    /// Nil where the message can't be forwarded.
    var onForward: ((Message) -> Void)?
    /// How many replies the thread this message starts has; nil when it starts none, or it
    /// is the thread on screen.
    var threadReplies: Int?
    /// Nil outside threads, and inside the one that is open.
    var onOpenThread: ((MessageThread) -> Void)?
    /// Nil where the thread can't be renamed by this user, or there is none.
    var onRenameThread: ((MessageThread) -> Void)?
    var threadNotificationLevel: ThreadNotificationLevel?
    var onSetThreadNotifications: ((MessageThread, ThreadNotificationLevel) -> Void)?
    /// The reminder set on this message, if any.
    var reminder: Reminder?
    /// Nil where reminders can't be set.
    var onRemind: ((Date) -> Void)?
    /// Asks for a date and time of the user's own.
    var onCustomReminder: ((Message) -> Void)?
    var onRemoveReminder: (Reminder) -> Void = { _ in }
    /// The pin on this message, if it is pinned.
    var pin: PinnedMessage?
    /// Nil where this user can't pin.
    var onPin: ((PinDuration) -> Void)?
    var onUnpin: (Int) -> Void = { _ in }
    var onEdit: (Message) -> Void
    var onDelete: (Message) -> Void
    var onReact: (String, Message) -> Void
    var onRetry: (Message) -> Void
    var onDiscard: (Message) -> Void
    var onShowParent: (Int) -> Void
    /// Its translation, when there is one to show.
    var translation: MessageTranslator.Display?
    /// Nil where there's nothing to translate.
    var onTranslate: ((Message) -> Void)?
    var onShowOriginal: (Message) -> Void = { _ in }
    /// Nil where the message mentions no day or time.
    var onAddToCalendar: ((Message) -> Void)?
    var onAddToReminders: ((Message) -> Void)?
    /// True while this message's reactions float above it — see `TapbackBar`.
    var isTapbackTarget = false
    var onShowTapback: (Message) -> Void

    @State private var isShowingReactionDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.talkSession) private var session
    @Environment(\.isTranscriptScrolling) private var isScrolling

    var body: some View {
        if message.isSystem {
            SystemMessageRow(message: message, content: content)
        } else {
            messageBody
        }
    }

    private var messageBody: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isFromMe {
                // Your own messages hug the right edge; no avatar, you know who you are.
                Spacer(minLength: 48)
            } else {
                // The gutter keeps grouped messages aligned with the first one's text.
                Group {
                    if group.showsAvatar {
                        ActorAvatarView(actor: message.actor, size: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                }
            }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if group.showsHeader { header }
                if threadReplies != nil, let thread = message.thread, !thread.title.isEmpty {
                    ThreadTitle(title: thread.title)
                }
                if let parent = message.parent { QuotedMessageView(parent: parent, onTap: { onShowParent(parent.messageID) }) }

                bubble
                    // The reactions hang off the bubble's top corner, the far one from
                    // the sender, reaching a little above and beyond it. The room above
                    // is made here, so they never sit on the message before.
                    .padding(.top, message.reactions.isEmpty ? 0 : 14)
                    .overlay(alignment: isFromMe ? .topLeading : .topTrailing) {
                        if !message.reactions.isEmpty {
                            ReactionBadges(
                                reactions: message.reactions,
                                mine: message.myReactions,
                                isFromMe: isFromMe,
                                isEnabled: capabilities.supportsReactions,
                                onToggle: { onReact($0, message) }
                            )
                            .offset(x: isFromMe ? -10 : 10, y: 0)
                            .popover(isPresented: $isShowingReactionDetail, arrowEdge: .bottom) {
                                if let session { ReactionDetailPopover(message: message, session: session) }
                            }
                        }
                    }

                if !message.isDeleted, let link = content.firstWebLink {
                    LinkPreviewCard(url: link, isFromMe: isFromMe)
                        .padding(.top, 2)
                }

                if let threadReplies, let openThread {
                    ThreadRepliesButton(count: threadReplies, action: openThread)
                }

                if message.deliveryState.isPending { deliveryStatus }

                if pin != nil || reminder != nil {
                    HStack(spacing: 8) {
                        if let pin {
                            Label("Pinned", systemImage: "pin.fill")
                                .help(pinnedHelp(pin))
                        }
                        if let reminder {
                            Label(ReminderTime.text(reminder.date), systemImage: "alarm")
                                .help("You’ll be reminded about this message")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            // A bubble that runs the full width of a wide window is a wall of text, not a
            // message. Past this the line length stops being comfortable to read anyway.
            .frame(maxWidth: 520, alignment: isFromMe ? .trailing : .leading)

            if !isFromMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
        .padding(.top, group.showsHeader ? 8 : 1)
        .padding(.bottom, 1)
        .contentShape(.rect)
        // Right-click: reactions and actions in one menu, as in Messages. The host
        // takes only right clicks; everything else reaches the row as before.
        .overlay {
            if isActionable {
                MessageMenuHost(actions: menuActions)
            }
        }
        .background(alignment: .leading) {
            if content.mentionsCurrentUser {
                // A quiet tint rather than a badge: you notice it, it doesn't shout.
                Color.accentColor.opacity(0.07)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func pinnedHelp(_ pin: PinnedMessage) -> String {
        let name = pin.pinnedBy.resolvedDisplayName
        guard let until = pin.pinnedUntil else {
            return String(localized: "Pinned by \(name)", comment: "Tooltip on a pinned message; %@ is who pinned it")
        }
        return String(localized: "Pinned by \(name) until \(until.formatted(date: .abbreviated, time: .shortened))", comment: "Tooltip on a pinned message; who pinned it, and the date and time the pin ends")
    }

    /// VoiceOver reads one coherent sentence per message rather than a pile of fragments.
    private var accessibilityLabel: String {
        var parts = [message.actor.resolvedDisplayName]
        if message.isDeleted {
            parts.append(String(localized: "message deleted", comment: "VoiceOver, part of a message's description"))
        } else {
            parts.append(content.preview)
        }
        if let parent = message.parent {
            parts.append(String(localized: "replying to \(parent.actor.resolvedDisplayName)", comment: "VoiceOver, part of a message's description; %@ is a name"))
        }
        if message.lastEdit != nil { parts.append(String(localized: "edited")) }
        if !message.reactions.isEmpty {
            let total = message.reactions.values.reduce(0, +)
            parts.append(String(localized: "\(total) reactions", comment: "VoiceOver, part of a message's description"))
        }
        if case .failed(let reason) = message.deliveryState {
            parts.append(String(localized: "not sent: \(reason)", comment: "VoiceOver, part of a message's description; %@ is why"))
        }
        parts.append(message.timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }

    /// The message in a bubble: accent-tinted when it's yours, a quiet fill when it isn't.
    /// A deleted message gets no bubble — there is nothing to contain.
    @ViewBuilder
    private var bubble: some View {
        if message.isDeleted || message.kind == .commentDeleted {
            content_
        } else {
            Group {
                if content.standalone != nil {
                    // A picture and a poll are shapes already; a bubble around one only
                    // makes its own fill fight the thing it is holding. The caption gets a
                    // small bubble of its own instead — see `MessageContentView`.
                    content_
                } else {
                    content_.messageBubble(isFromMe: isFromMe)
                }
            }
            // Press and hold, and the reactions float up above the message. It lifts a
            // touch while they are up, as it does in Messages. Outside the branch above:
            // a picture is as reactable as a sentence.
            .scaleEffect(isTapbackTarget ? 1.04 : 1, anchor: isFromMe ? .bottomTrailing : .bottomLeading)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isTapbackTarget)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 6) {
                if isActionable && capabilities.supportsReactions { onShowTapback(message) }
            }
            // Where the message is, for the transcript to place the bar.
            .anchorPreference(key: TapbackAnchorKey.self, value: .bounds) { anchor in
                isTapbackTarget ? [message.messageID: TapbackAnchor(bounds: anchor, isFromMe: isFromMe)] : [:]
            }
        }
    }

    /// Secondary marks inside a bubble can't use `.tertiary` — it disappears on accent.
    private var bubbleSecondary: AnyShapeStyle {
        isFromMe ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
    }

    @ViewBuilder
    private var content_: some View {
        if message.isDeleted || message.kind == .commentDeleted {
            Label("Message deleted", systemImage: "trash")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .italic()
        } else if let translation {
            VStack(alignment: .leading, spacing: 6) {
                original
                translated(translation)
            }
        } else {
            original
        }
    }

    /// Under the original, set off by a hairline: the translation and where it's from — or,
    /// asked for from the menu, that it's on its way or why it couldn't be done.
    @ViewBuilder
    private func translated(_ translation: MessageTranslator.Display) -> some View {
        Rectangle()
            .fill(bubbleSecondary)
            .frame(height: 0.5)
            .opacity(0.6)
        switch translation {
        case .working:
            Label("Translating…", systemImage: "translate")
                .font(.caption)
                .foregroundStyle(bubbleSecondary)
        case .done(let text, let fromName):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label("Translated from \(fromName)", systemImage: "translate")
                .font(.caption2)
                .foregroundStyle(bubbleSecondary)
        case .problem(let reason):
            Label(reason, systemImage: "translate")
                .font(.caption)
                .foregroundStyle(bubbleSecondary)
        }
    }

    private var original: some View {
        HStack(alignment: .bottom, spacing: 6) {
            MessageContentView(content: content, isFromMe: isFromMe)
                .font(.body)
                .opacity(message.deliveryState.isPending ? 0.6 : 1)
            if message.lastEdit != nil {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(bubbleSecondary)
                    .help(editedHelp)
            }
            if message.isSilent && capabilities.showsSilentState {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(bubbleSecondary)
                    .help("Sent without a notification")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !isFromMe {
                Text(message.actor.resolvedDisplayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if !isFromMe, message.actor.isBot {
                Text("BOT")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
                    .foregroundStyle(.secondary)
            }
            if !isFromMe, let server = message.actor.federationServer {
                Text(server)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(message.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                // Hovering gives the full date — precision on demand, not by default.
                .help(message.timestamp.formatted(date: .complete, time: .standard))
        }
    }

    private var editedHelp: String {
        guard let edit = message.lastEdit else { return "" }
        return String(localized: "Edited by \(edit.actor.resolvedDisplayName) at \(edit.timestamp.formatted(date: .abbreviated, time: .shortened))", comment: "Tooltip; %1$@ is a name, %2$@ a date and time")
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch message.deliveryState {
        case .sending:
            Text("Sending…").font(.caption2).foregroundStyle(.tertiary)
        case .queued:
            Label("Waiting for a connection", systemImage: "clock")
                .font(.caption2).foregroundStyle(.tertiary)
        case .failed(let reason):
            HStack(spacing: 6) {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button("Try Again") { onRetry(message) }
                    .buttonStyle(.link)
                    .font(.caption2)
                Button("Delete") { onDiscard(message) }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        case .sent:
            EmptyView()
        }
    }

    private var openThread: (() -> Void)? {
        guard let onOpenThread, let thread = message.thread else { return nil }
        return { onOpenThread(thread) }
    }

    /// Deleted and not-yet-sent messages have no menu and no reactions.
    private var isActionable: Bool {
        !message.isDeleted && message.kind != .commentDeleted && !message.deliveryState.isPending
    }

    private var menuActions: MessageMenuActions {
        MessageMenuActions(
            canReply: message.isReplyable && capabilities.supportsReplies,
            canEdit: canEdit,
            canDelete: canDelete,
            canReact: capabilities.supportsReactions,
            hasReactions: !message.reactions.isEmpty,
            myReactions: message.myReactions,
            onReply: { onReply(message) },
            onReplyPrivately: onReplyPrivately.map { handler in { handler(message) } },
            onOpenThread: openThread,
            onRenameThread: message.thread.flatMap { thread in onRenameThread.map { handler in { handler(thread) } } },
            threadNotificationLevel: message.thread == nil ? nil : threadNotificationLevel,
            onSetThreadNotifications: message.thread.flatMap { thread in onSetThreadNotifications.map { handler in { handler(thread, $0) } } },
            onForward: onForward.map { handler in { handler(message) } },
            reminder: reminder?.date,
            onRemind: onRemind,
            onCustomReminder: onRemind == nil ? nil : onCustomReminder.map { handler in { handler(message) } },
            onRemoveReminder: reminder.map { reminder in { onRemoveReminder(reminder) } },
            isPinned: pin != nil,
            onPin: onPin,
            onUnpin: { onUnpin(message.messageID) },
            onEdit: { onEdit(message) },
            onDelete: { onDelete(message) },
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content.preview, forType: .string)
            },
            onTranslate: onTranslate.map { handler in { handler(message) } },
            isTranslated: { if case .done = translation { true } else { false } }(),
            onShowOriginal: { onShowOriginal(message) },
            onAddToCalendar: onAddToCalendar.map { handler in { handler(message) } },
            calendarText: onAddToCalendar == nil ? nil : content.preview,
            onAddToReminders: onAddToReminders.map { handler in { handler(message) } },
            onReact: { onReact($0, message) },
            onShowReactions: { isShowingReactionDetail = true },
            onMoreReactions: { onShowTapback(message) },
            links: content.webLinks
        )
    }

    private var canEdit: Bool {
        isFromMe && message.isEditable && capabilities.canEditMessages
    }

    private var canDelete: Bool {
        message.isDeletable && capabilities.canDelete(message)
    }
}

/// Join/leave/call events, rendered as quiet centred text rather than as messages.
private struct SystemMessageRow: View {
    let message: Message
    let content: MessageContent

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(content.preview)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .help(message.timestamp.formatted(date: .abbreviated, time: .shortened))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }
}

/// A run of system events on one line — "Anna, Bo and Carl joined and left the call" —
/// that opens to the events themselves.
struct SystemMessageGroupRow: View {
    let group: SystemMessageGroup
    let content: (Message) -> MessageContent

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(group.summary)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(timeRange)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(isExpanded ? Text("Hides the events") : Text("Shows each event"))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(group.messages, id: \.localID) { message in
                    SystemMessageRow(message: message, content: content(message))
                        .padding(.vertical, -2)
                }
                .transition(.opacity)
            }
        }
    }

    /// When the first and the last of them happened.
    private var timeRange: String {
        guard let first = group.messages.first?.timestamp, let last = group.messages.last?.timestamp else { return "" }
        let from = first.formatted(date: .abbreviated, time: .shortened)
        let to = last.formatted(date: .omitted, time: .shortened)
        return from.hasSuffix(to) ? from : "\(from) – \(to)"
    }
}

/// The compact quote shown above a reply.
struct QuotedMessageView: View {
    let parent: ParentMessage
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(parent.actor.resolvedDisplayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(parent.isDeleted ? String(localized: "Message deleted") : preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .italic(parent.isDeleted)
                }
            }
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .help("Jump to the replied-to message")
    }

    private var preview: String {
        MessageContentParser(currentUserID: "", markdownEnabled: false)
            .parse(text: parent.text, parameters: parent.parameters, isMarkdown: false)
            .preview
    }
}
