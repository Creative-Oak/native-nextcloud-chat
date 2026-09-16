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
    var onEdit: (Message) -> Void
    var onDelete: (Message) -> Void
    var onReact: (String, Message) -> Void
    var onRetry: (Message) -> Void
    var onDiscard: (Message) -> Void
    var onShowParent: (Int) -> Void
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

                if message.deliveryState.isPending { deliveryStatus }
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

    /// VoiceOver reads one coherent sentence per message rather than a pile of fragments.
    private var accessibilityLabel: String {
        var parts = [message.actor.resolvedDisplayName]
        if message.isDeleted {
            parts.append("message deleted")
        } else {
            parts.append(content.preview)
        }
        if let parent = message.parent {
            parts.append("replying to \(parent.actor.resolvedDisplayName)")
        }
        if message.lastEdit != nil { parts.append("edited") }
        if !message.reactions.isEmpty {
            let total = message.reactions.values.reduce(0, +)
            parts.append("\(total) reaction\(total == 1 ? "" : "s")")
        }
        if case .failed(let reason) = message.deliveryState { parts.append("not sent: \(reason)") }
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
        } else {
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
        return "Edited by \(edit.actor.resolvedDisplayName) at \(edit.timestamp.formatted(date: .abbreviated, time: .shortened))"
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
            onEdit: { onEdit(message) },
            onDelete: { onDelete(message) },
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content.preview, forType: .string)
            },
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
                    Text(parent.isDeleted ? "Message deleted" : preview)
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
