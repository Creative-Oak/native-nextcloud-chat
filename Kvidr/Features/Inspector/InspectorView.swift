import AppKit
import SwiftUI

/// The third column: who's here, what's been shared, and what this conversation is.
///
/// Shaped like a contact card rather than a settings pane: who this is, large, then the
/// handful of things you can do about it as round buttons, then the tabs. Everything below
/// sits in grouped cards, so the panel reads as a stack of objects instead of a wall of
/// label-and-value pairs.
struct InspectorView: View {
    @Bindable var model: InspectorModel
    var onOpenMessage: (Int) -> Void

    @Environment(\.talkSession) private var session
    @State private var settings: ConversationSettingsModel?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                identity
                actions
                picker
            }
            .padding(.top, 18)
            .padding(.bottom, 12)

            // A grouped Form rather than cards drawn by hand. The rounded sections,
            // their insets, their dividers and the way they respond to the theme are all
            // AppKit's — which is the only way this ends up looking like the rest of the
            // system rather than like an approximation of it.
            Form {
                switch model.tab {
                case .details: DetailsTab(model: model)
                case .people: PeopleTab(model: model)
                case .files: FilesTab(model: model, onOpenMessage: onOpenMessage)
                }
            }
            .formStyle(.grouped)
            // The Form paints an opaque background of its own, which sat on top of
            // the recessed tint below and left the whole panel flat white.
            .scrollContentBackground(.hidden)
        }
        .overlay {
            if model.isLoading && model.participants.isEmpty && model.sharedItems.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
        // A grouped form only reads as grouped when it sits on something recessed —
        // white rows on a white panel are just text. windowBackgroundColor comes out
        // white here, so the tint is explicit: the page colour with a few percent of
        // `primary` over it, which darkens in light mode and lifts in dark.
        .background {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Color.primary.opacity(0.045)
            }
        }
        .task(id: model.conversation.token) { await model.loadIfNeeded() }
        .sheet(item: $settings) { model in
            ConversationSettingsSheet(model: model)
        }
    }

    /// The card's face: big avatar, the name at title weight, status underneath.
    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(conversation: model.conversation, size: 80)
            Text(model.conversation.displayName)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    /// Only things this app can actually do. No placeholder buttons.
    private var actions: some View {
        HStack(spacing: 16) {
            InspectorAction(symbol: "link", label: "Copy Link") {
                guard let url = webURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            InspectorAction(symbol: "arrow.up.forward.app", label: "Open in Nextcloud") {
                guard let url = webURL else { return }
                NSWorkspace.shared.open(url)
            }
            if let session, model.conversation.isModerator || model.conversation.canLeaveConversation {
                InspectorAction(symbol: "gearshape", label: "Conversation Settings…") {
                    settings = ConversationSettingsModel(session: session, conversation: model.conversation)
                }
            }
        }
    }

    private var webURL: URL? {
        session?.account.server.url(path: "/index.php/call/\(model.conversation.token)")
    }

    private var subtitle: String? {
        let conversation = model.conversation
        if let status = conversation.userStatus, let message = status.message, !message.isEmpty {
            return [status.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if conversation.isNoteToSelf { return "Only you can see this" }
        return nil
    }

    /// Words, not icons. Three glyphs in a segmented control is a guessing game, and there
    /// is room for the labels.
    private var picker: some View {
        Picker("", selection: $model.tab) {
            ForEach(model.availableTabs) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
    }
}

/// One of the round buttons under the name.
private struct InspectorAction: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: .circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Info

private struct DetailsTab: View {
    @Bindable var model: InspectorModel

    /// A property rather than a `let` at the top of `body`, so `body` can be a plain run
    /// of Sections for the Form to lay out.
    private var conversation: Conversation { model.conversation }

    var body: some View {
        if !conversation.description.isEmpty {
            Section("Description") {
                Text(conversation.description)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Conversation") {
            LabeledContent("Type", value: typeDescription)
            if conversation.hasPassword {
                LabeledContent("Password", value: "Required")
            }
            if conversation.isReadOnly {
                LabeledContent("Posting", value: "Read-only")
            }
            if conversation.messageExpiration > 0 {
                LabeledContent("Messages expire", value: expiration)
            }
            LabeledContent(
                "Last activity",
                value: conversation.lastActivity.formatted(date: .abbreviated, time: .shortened)
            )
        }

        if model.capabilities.supportsNotificationLevels {
            Section("Notifications") {
                LabeledContent("Level", value: conversation.notificationLevel.title)
                Text("Change this by right-clicking the conversation in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.token, forType: .string)
            } label: {
                Label("Copy Conversation Token", systemImage: "doc.on.doc")
            }
            .buttonStyle(.link)
        }
    }

    private var typeDescription: String {
        switch model.conversation.type {
        case .oneToOne: "Direct message"
        case .formerOneToOne: "Direct message (account deleted)"
        case .group: "Private group"
        case .publicRoom: "Open conversation"
        case .noteToSelf: "Note to self"
        case .changelog: "Talk updates"
        }
    }

    private var expiration: String {
        // `Duration`'s own format style rather than DateComponentsFormatter: it is the
        // modern API, it localizes the same way, and it works everywhere.
        Duration.seconds(model.conversation.messageExpiration)
            .formatted(.units(allowed: [.weeks, .days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
    }
}

// MARK: - People

private struct PeopleTab: View {
    @Bindable var model: InspectorModel

    var body: some View {
        if model.canManageParticipants {
            Section { inviteField }
        }

        Section("Participants") {
            if model.participants.isEmpty && !model.isLoading {
                Text("No participants to show.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.participants) { participant in
                ParticipantRow(participant: participant, canRemove: canRemove(participant)) {
                    Task { await model.remove(participant) }
                }
            }
        }
    }

    private func canRemove(_ participant: Participant) -> Bool {
        // Never offer to remove yourself from here — that's "Leave conversation".
        model.canManageParticipants && participant.actor.id != model.conversation.actor.id
    }

    private var inviteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                TextField("Add someone", text: $model.inviteSearch)
                    .textFieldStyle(.plain)
                if model.isInviting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glass(.floating, cornerRadius: 8)

            if !model.inviteResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.inviteResults) { entry in
                        Button {
                            Task { await model.invite(entry) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.source.symbolName)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(entry.label).lineLimit(1)
                                    if let subline = entry.subline, !subline.isEmpty {
                                        Text(subline)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glass(.panel, cornerRadius: 8)
            }
        }
    }
}

private struct ParticipantRow: View {
    let participant: Participant
    let canRemove: Bool
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ActorAvatarView(actor: participant.actor, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    if participant.isOnline {
                        Circle()
                            .fill(participant.status?.isDoNotDisturb == true ? Color.red : .green)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(participant.displayName)
                        .lineLimit(1)
                    if participant.isModerator {
                        Text(participant.participantType == .owner ? "Owner" : "Moderator")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if participant.isInCall {
                Image(systemName: "phone.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("In the call")
            }

            if canRemove && isHovering {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from conversation")
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .contextMenu {
            if canRemove {
                Button("Remove from Conversation", role: .destructive, action: onRemove)
            }
            Button("Copy User ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(participant.actor.id, forType: .string)
            }
        }
    }

    private var detail: String? {
        if let message = participant.status?.message, !message.isEmpty {
            return [participant.status?.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if participant.actor.isFederated { return participant.actor.federationServer }
        if participant.actor.kind == .guests { return "Guest" }
        return nil
    }
}

// MARK: - Files

private struct FilesTab: View {
    @Bindable var model: InspectorModel
    var onOpenMessage: (Int) -> Void

    var body: some View {
        if model.populatedItemTypes.isEmpty && !model.isLoading {
            Section {
                Text("Nothing has been shared here yet.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(model.populatedItemTypes) { type in
            Section(type.title) {
                ForEach(model.items(for: type)) { message in
                    SharedItemRow(message: message) { onOpenMessage(message.messageID) }
                }
            }
        }
    }
}

private struct SharedItemRow: View {
    let message: Message
    var onOpen: () -> Void

    private var object: RichObject? {
        message.parameters.values.first { MessageContentParser.isAttachment($0) }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(object?.name ?? "Attachment")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show in conversation")
        .contextMenu {
            if let link = object?.link {
                Button("Open in Nextcloud") { NSWorkspace.shared.open(link) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
            Button("Show in Conversation", action: onOpen)
        }
    }

    private var symbol: String {
        guard let object else { return "doc" }
        if object.isImage { return "photo" }
        if object.isVideo { return "film" }
        switch object.type {
        case .talkPoll: return "chart.bar"
        case .geoLocation: return "mappin.and.ellipse"
        default: return "doc"
        }
    }
}
