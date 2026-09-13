import AppKit
import SwiftUI

/// The third column: who's here, what's been shared, and what this conversation is.
///
/// A Mac inspector, not a reproduction of Talk's web sidebar — a segmented picker at the
/// top, plain grouped content below, and no chrome competing with the transcript.
struct InspectorView: View {
    @Bindable var model: InspectorModel
    var onOpenMessage: (Int) -> Void

    @Environment(\.talkSession) private var session
    @State private var settings: ConversationSettingsModel?

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.tab {
                    case .details: DetailsTab(model: model)
                    case .people: PeopleTab(model: model)
                    case .files: FilesTab(model: model, onOpenMessage: onOpenMessage)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if model.isLoading && model.participants.isEmpty && model.sharedItems.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
        .background(.regularMaterial)
        .task(id: model.conversation.token) { await model.loadIfNeeded() }
        .safeAreaInset(edge: .bottom) {
            if let session, model.conversation.isModerator || model.conversation.canLeaveConversation {
                Button {
                    settings = ConversationSettingsModel(session: session, conversation: model.conversation)
                } label: {
                    Label("Conversation Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .padding(10)
            }
        }
        .sheet(item: $settings) { model in
            ConversationSettingsSheet(model: model)
        }
    }

    private var picker: some View {
        Picker("", selection: $model.tab) {
            ForEach(model.availableTabs) { tab in
                Label(tab.title, systemImage: tab.symbolName)
                    .labelStyle(.iconOnly)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
    }
}

// MARK: - Info

private struct DetailsTab: View {
    @Bindable var model: InspectorModel

    var body: some View {
        let conversation = model.conversation

        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                AvatarView(conversation: conversation, size: 72)
                Text(conversation.displayName)
                    .font(.title3.weight(.semibold))
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

            if !conversation.description.isEmpty {
                InspectorSection("Description") {
                    Text(conversation.description)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorSection("Conversation") {
                InspectorRow(label: "Type", value: typeDescription)
                if conversation.hasPassword {
                    InspectorRow(label: "Password", value: "Required", symbol: "lock")
                }
                if conversation.isReadOnly {
                    InspectorRow(label: "Posting", value: "Read-only", symbol: "pencil.slash")
                }
                if conversation.messageExpiration > 0 {
                    InspectorRow(label: "Messages expire", value: expiration)
                }
                InspectorRow(label: "Last activity", value: conversation.lastActivity.formatted(date: .abbreviated, time: .shortened))
            }

            if model.capabilities.supportsNotificationLevels {
                InspectorSection("Notifications") {
                    Text(conversation.notificationLevel.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Change this by right-clicking the conversation in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            InspectorSection("") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(conversation.token, forType: .string)
                } label: {
                    Label("Copy Conversation Token", systemImage: "doc.on.doc")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.horizontal, 16)
    }

    private var subtitle: String? {
        let conversation = model.conversation
        if let status = conversation.userStatus, let message = status.message, !message.isEmpty {
            return [status.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if conversation.isNoteToSelf { return "Only you can see this" }
        return nil
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
        let seconds = model.conversation.messageExpiration
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }
}

// MARK: - People

private struct PeopleTab: View {
    @Bindable var model: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.canManageParticipants {
                inviteField
                    .padding(.horizontal, 16)
            }

            if model.participants.isEmpty && !model.isLoading {
                Text("No participants to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
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
        .padding(.horizontal, 16)
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
        VStack(alignment: .leading, spacing: 14) {
            if model.populatedItemTypes.isEmpty && !model.isLoading {
                Text("Nothing has been shared here yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            ForEach(model.populatedItemTypes) { type in
                InspectorSection(type.title) {
                    ForEach(model.items(for: type)) { message in
                        SharedItemRow(message: message) { onOpenMessage(message.messageID) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
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

// MARK: - Small pieces

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
