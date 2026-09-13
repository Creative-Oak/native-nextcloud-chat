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
    var onEdit: (Message) -> Void
    var onDelete: (Message) -> Void
    var onReact: (String, Message) -> Void
    var onRetry: (Message) -> Void
    var onDiscard: (Message) -> Void
    var onShowParent: (Int) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if message.isSystem {
            SystemMessageRow(message: message, content: content)
        } else {
            messageBody
        }
    }

    private var messageBody: some View {
        HStack(alignment: .top, spacing: 8) {
            // The gutter keeps grouped messages aligned with the first one's text.
            Group {
                if group.showsAvatar {
                    ActorAvatarView(actor: message.actor, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if group.showsHeader { header }
                if let parent = message.parent { QuotedMessageView(parent: parent, onTap: { onShowParent(parent.messageID) }) }

                content_

                if !message.reactions.isEmpty {
                    ReactionStrip(
                        reactions: message.reactions,
                        mine: message.myReactions,
                        isEnabled: capabilities.supportsReactions,
                        onToggle: { onReact($0, message) }
                    )
                    .padding(.top, 2)
                }

                if message.deliveryState.isPending { deliveryStatus }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, group.showsHeader ? 8 : 1)
        .padding(.bottom, 1)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .overlay(alignment: .topTrailing) { hoverActions }
        .contextMenu { MessageContextMenu(
            message: message,
            content: content,
            capabilities: capabilities,
            canEdit: canEdit,
            canDelete: canDelete,
            onReply: onReply, onEdit: onEdit, onDelete: onDelete, onReact: onReact
        ) }
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

    @ViewBuilder
    private var content_: some View {
        if message.isDeleted || message.kind == .commentDeleted {
            Label("Message deleted", systemImage: "trash")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .italic()
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                MessageContentView(content: content, isFromMe: false)
                    .font(.body)
                    .opacity(message.deliveryState.isPending ? 0.6 : 1)
                if message.lastEdit != nil {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(editedHelp)
                }
                if message.isSilent && capabilities.showsSilentState {
                    Image(systemName: "bell.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Sent without a notification")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(message.actor.resolvedDisplayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFromMe ? Color.accentColor : .primary)
            if message.actor.isBot {
                Text("BOT")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
                    .foregroundStyle(.secondary)
            }
            if let server = message.actor.federationServer {
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

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering, !message.isDeleted, !message.deliveryState.isPending {
            MessageHoverActions(
                message: message,
                capabilities: capabilities,
                canEdit: canEdit,
                canDelete: canDelete,
                onReply: onReply, onEdit: onEdit, onDelete: onDelete, onReact: onReact
            )
            .padding(.trailing, 16)
            .transition(reduceMotion ? .identity : .opacity)
        }
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
