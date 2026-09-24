import AppKit
import SwiftUI

/// The third column: who's here, what's been shared, and what this conversation is.
///
/// Shaped like Messages' contact card rather than a settings pane: who this is, large,
/// then the handful of things you can do about it as round buttons, then the tabs, then
/// the information as a stack of rounded cards with a label over each value. Close and
/// Edit live in the toolbar band above the card, where Messages puts them — see
/// `RootView.detailToolbar`.
struct InspectorView: View {
    @Bindable var model: InspectorModel
    var onOpenMessage: (Int) -> Void
    /// Opens the in-conversation search — the transcript's, not the app-wide sheet.
    var onSearch: () -> Void
    /// Breakout rooms: the open conversation's, when it can have them, and the way to one.
    var breakout: BreakoutRoomsModel?
    var breakoutRooms: [Conversation] = []
    /// The conversation as the sidebar last synced it — rooms set up or started since the
    /// inspector opened show there, not in its snapshot.
    var liveConversation: Conversation?
    var onOpenConversation: (String) -> Void = { _ in }

    @Environment(\.talkSession) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                identity
                actions
                InspectorTabBar(selection: $model.tab, tabs: model.availableTabs)

                VStack(spacing: 14) {
                    switch model.tab {
                    case .details:
                        DetailsTab(model: model)
                        if let session, model.conversation.isModerator, !model.conversation.isFormerOneToOne,
                           model.capabilities.has("bots-v1") {
                            BotsCard(session: session, token: model.conversation.token)
                        }
                        if let breakout, showsBreakoutRooms {
                            BreakoutRoomsCard(
                                conversation: liveConversation ?? model.conversation,
                                rooms: breakoutRooms,
                                model: breakout,
                                onOpen: onOpenConversation
                            )
                        }
                    case .people: PeopleTab(model: model)
                    case .files: FilesTab(model: model, onOpenMessage: onOpenMessage)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .padding(.top, 12)
        }
        // The seam between transcript and panel, the full height of the window. A
        // `Divider` beside the panel stopped at the toolbar band and left its top end
        // showing as a stray dot.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .overlay {
            if model.isLoading && model.participants.isEmpty && model.sharedItems.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
        // Cards only read as cards when they sit on something recessed — white rows on
        // a white panel are just text. windowBackgroundColor comes out white here, so
        // the tint is explicit: the page colour with a few percent of `primary` over it
        // in light mode; in dark the page colour as it is, and the cards lift instead.
        // A wash of the accent behind the face, fading out by the tabs, is what keeps
        // the top of the panel from being a flat grey field.
        .background {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if colorScheme == .light { Color.primary.opacity(0.045) }
                LinearGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.32)
                )
            }
            .ignoresSafeArea()
        }
        .task(id: model.conversation.token) { await model.loadIfNeeded() }
    }

    /// The card's face: big avatar, the name at title weight, status underneath.
    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(conversation: model.conversation, size: 72)
                .padding(.bottom, 2)
            Text(model.conversation.displayName)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
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
            InspectorAction(symbol: "magnifyingglass", label: String(localized: "Search in Conversation"), action: onSearch)
            InspectorAction(symbol: "link", label: String(localized: "Copy Link")) {
                guard let url = webURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            InspectorAction(symbol: "safari", label: String(localized: "Open in Nextcloud")) {
                guard let url = webURL else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Moderators of a group or public conversation, on a server that has breakout rooms.
    private var showsBreakoutRooms: Bool {
        model.conversation.isModerator && model.conversation.canHostBreakoutRooms
            && model.capabilities.has("breakout-rooms-v1")
            && breakout?.token == model.conversation.token
    }

    private var webURL: URL? {
        session?.account.server.url(path: "/index.php/call/\(model.conversation.token)")
    }

    private var subtitle: String? {
        let conversation = model.conversation
        if let status = conversation.userStatus, let message = status.message, !message.isEmpty {
            return [status.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if conversation.isNoteToSelf { return String(localized: "Only you can see this", comment: "Inspector subtitle for a note-to-self conversation") }
        return nil
    }
}

/// One of the round glass buttons under the name — the same control as the composer's
/// plus and the transcript's scroll-to-bottom, so the three read as one family.
struct InspectorAction: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: GlassMetrics.control, height: GlassMetrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassCircle()
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The tabs, as Messages draws them: words in a row, the current one on a grey pill that
/// slides across when the selection changes. Three glyphs in a segmented control would be
/// a guessing game, and there is room for the labels.
private struct InspectorTabBar: View {
    @Binding var selection: InspectorModel.Tab
    let tabs: [InspectorModel.Tab]

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.quaternary)
                                    .matchedGeometryEffect(id: "selected", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }
}

// MARK: - Cards

/// A rounded card of rows with a hairline between each, the way Messages' info panel
/// stacks its information. A caption above names the group when one is needed.
struct InspectorCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .background {
                // White on the light panel; on the dark one, a lift over the page colour.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
            }
        }
    }
}

/// A small grey label over its value.
struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row that does something: accent-coloured words, as in Messages.
struct InspectorActionRow: View {
    let title: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

// MARK: - Info

private struct DetailsTab: View {
    @Bindable var model: InspectorModel

    /// A property rather than a `let` at the top of `body`, so `body` can be a plain run
    /// of cards for the stack to lay out.
    private var conversation: Conversation { model.conversation }

    var body: some View {
        if !conversation.description.isEmpty {
            InspectorCard {
                Text(conversation.description)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        InspectorCard(title: String(localized: "Conversation", comment: "Inspector card heading")) {
            InspectorRow(label: String(localized: "Type", comment: "Inspector row label: the kind of conversation"), value: typeDescription)
            if conversation.hasPassword {
                InspectorRow(
                    label: String(localized: "Password", comment: "Inspector row label"),
                    value: String(localized: "Required", comment: "Inspector row value: the conversation needs a password")
                )
            }
            if conversation.isReadOnly {
                InspectorRow(
                    label: String(localized: "Posting", comment: "Who can post in the conversation"),
                    value: String(localized: "Read-only", comment: "Only moderators can post")
                )
            }
            if conversation.messageExpiration > 0 {
                InspectorRow(label: String(localized: "Messages expire", comment: "Inspector row label; the value is a duration"), value: expiration)
            }
            InspectorRow(
                label: String(localized: "Last activity", comment: "Inspector row label; the value is a date"),
                value: conversation.lastActivity.formatted(date: .abbreviated, time: .shortened)
            )
        }

        if model.capabilities.supportsNotificationLevels {
            InspectorCard(title: String(localized: "Notifications")) {
                InspectorRow(label: String(localized: "Level", comment: "Inspector row label: the notification level"), value: conversation.notificationLevel.title)
                Text("Change this by right-clicking the conversation in the sidebar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        InspectorCard {
            InspectorActionRow(title: String(localized: "Copy Conversation Token")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.token, forType: .string)
            }
        }
    }

    private var typeDescription: String {
        switch model.conversation.type {
        case .oneToOne: String(localized: "Direct message", comment: "Conversation type")
        case .formerOneToOne: String(localized: "Direct message (account deleted)", comment: "Conversation type")
        case .group: String(localized: "Private group", comment: "Conversation type")
        case .publicRoom: String(localized: "Open conversation", comment: "Conversation type: anyone with the link can join (adjective, not a verb)")
        case .noteToSelf: String(localized: "Note to self", comment: "Conversation type")
        case .changelog: String(localized: "Talk updates", comment: "Conversation type: Talk's changelog conversation")
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
            InspectorCard {
                inviteField
                ForEach(model.inviteResults) { entry in
                    inviteResult(entry)
                }
            }
        }

        InspectorCard(title: String(localized: "Participants", comment: "Inspector card heading")) {
            if model.participants.isEmpty && !model.isLoading {
                Text("No participants to show.")
                    .font(.system(size: 13))
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
        HStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.secondary)
            TextField("Add someone", text: $model.inviteSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if model.isInviting { ProgressView().controlSize(.small) }
        }
    }

    private func inviteResult(_ entry: DirectoryEntry) -> some View {
        Button {
            Task { await model.invite(entry) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.source.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.label)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let subline = entry.subline, !subline.isEmpty {
                        Text(subline)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 13))
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
        if participant.actor.kind == .guests { return String(localized: "Guest", comment: "Participant detail: a guest, not a user") }
        return nil
    }
}

// MARK: - Files

private struct FilesTab: View {
    @Bindable var model: InspectorModel
    var onOpenMessage: (Int) -> Void

    var body: some View {
        if model.populatedItemTypes.isEmpty && !model.isLoading {
            InspectorCard {
                Text("Nothing has been shared here yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(model.populatedItemTypes) { type in
            InspectorCard(title: type.title) {
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
                    Text(object?.displayName ?? String(localized: "Attachment"))
                        .font(.system(size: 13))
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
                Button("Open in Nextcloud") { MessageLink.open(link) }
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
