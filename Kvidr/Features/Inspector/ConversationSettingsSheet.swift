import AppKit
import SwiftUI

/// Moderator settings for a conversation.
///
/// Only the things a chat client needs: what it's called, what it says it's for, whether
/// anyone can post, whether messages expire, whether a lobby holds people back, and how to
/// get out. Everything else Talk can
/// configure belongs in Talk's own settings, and pretending otherwise would make this a
/// worse chat app.
struct ConversationSettingsSheet: View {
    @Bindable var model: ConversationSettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation Settings").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .disabled(!model.canRename)
                    TextField("Description", text: $model.description, axis: .vertical)
                        .lineLimit(2...5)
                        .disabled(!model.canEditDescription)
                }

                if model.canModerate {
                    Section("Posting") {
                        Toggle("Read-only", isOn: $model.isReadOnly)
                            .disabled(!model.capabilities.has("read-only-rooms"))
                        Text("In a read-only conversation only moderators can post.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.capabilities.supportsMessageExpiration {
                        Section("Message expiration") {
                            Picker("Delete messages after", selection: $model.expiration) {
                                ForEach(ConversationSettingsModel.expirationOptions) { option in
                                    Text(option.title).tag(option.seconds)
                                }
                            }
                            Text("Applies to new messages. Existing ones are unaffected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.canSetLobby {
                        Section("Lobby") {
                            Toggle("Lobby", isOn: $model.isLobbyOn)
                            if model.isLobbyOn {
                                Toggle("Open automatically", isOn: $model.opensAutomatically)
                                if model.opensAutomatically {
                                    DatePicker("Opens", selection: $model.opensAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                }
                            }
                            Text("While the lobby is on, only moderators can see the conversation and join its call. Everyone else waits until it opens — at the time set here, or when a moderator opens it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.conversation.isPublic || model.conversation.type == .group {
                        Section("Access") {
                            Toggle("Anyone with the link can join", isOn: $model.isPublic)
                            if model.isPublic {
                                SecureField("Password (optional)", text: $model.password)
                                Button("Copy Link") { model.copyLink() }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }

                Section {
                    if model.conversation.canLeaveConversation {
                        Button("Leave Conversation", role: .destructive) {
                            Task { if await model.leave() { dismiss() } }
                        }
                    }
                    if model.conversation.canDeleteConversation {
                        Button("Delete Conversation…", role: .destructive) {
                            model.isConfirmingDelete = true
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isSaving ? "Saving…" : "Save") {
                    Task { if await model.save() { dismiss() } }
                }

                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasChanges || model.isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 520)
        .confirmationDialog("Delete this conversation?", isPresented: $model.isConfirmingDelete) {
            Button("Delete for Everyone", role: .destructive) {
                Task { if await model.delete() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every participant loses the conversation and its messages. This can't be undone.")
        }
    }
}

@MainActor
@Observable
final class ConversationSettingsModel: Identifiable {
    nonisolated var id: String { token }
    private let token: String

    var name: String
    var description: String
    var isReadOnly: Bool
    var isPublic: Bool
    var password = ""
    var expiration: Int
    var isLobbyOn: Bool
    var opensAutomatically: Bool
    var opensAt: Date
    var isConfirmingDelete = false

    private(set) var isSaving = false
    private(set) var error: String?

    let conversation: Conversation
    private let session: Session
    private let original: (name: String, description: String, readOnly: Bool, isPublic: Bool, expiration: Int)
    private let originalLobby: (isOn: Bool, opensAt: Date?)

    init(session: Session, conversation: Conversation) {
        self.session = session
        self.conversation = conversation
        self.token = conversation.token
        self.name = conversation.name
        self.description = conversation.description
        self.isReadOnly = conversation.isReadOnly
        self.isPublic = conversation.isPublic
        self.expiration = conversation.messageExpiration
        self.isLobbyOn = conversation.lobbyState == 1
        let opensAt = conversation.lobbyTimer.flatMap { $0 > .now ? $0 : nil }
        self.opensAutomatically = opensAt != nil
        // Unset, the next full hour: the likeliest start of a meeting.
        self.opensAt = opensAt ?? Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        self.originalLobby = (conversation.lobbyState == 1, opensAt)
        self.original = (
            conversation.name,
            conversation.description,
            conversation.isReadOnly,
            conversation.isPublic,
            conversation.messageExpiration
        )
    }

    var capabilities: TalkCapabilities { session.capabilitySnapshot }
    var canModerate: Bool { conversation.isModerator }
    /// One-to-ones take their name from the other person; renaming them isn't a thing.
    var canRename: Bool { canModerate && !conversation.isOneToOne && !conversation.isNoteToSelf }
    var canEditDescription: Bool { canRename && capabilities.has("room-description") }
    var canSetLobby: Bool { canModerate && conversation.supportsLobby && capabilities.has("webinary-lobby") }

    /// The opening time as it would be sent: only with the lobby on and set to open by itself.
    private var lobbyOpensAt: Date? { isLobbyOn && opensAutomatically ? opensAt : nil }

    var hasChanges: Bool {
        name != original.name
            || description != original.description
            || isReadOnly != original.readOnly
            || isPublic != original.isPublic
            || expiration != original.expiration
            || !password.isEmpty
            || isLobbyOn != originalLobby.isOn
            || lobbyOpensAt != originalLobby.opensAt
    }

    /// A struct, not a tuple: `ForEach(_:id:)` needs a key path and Swift has none into
    /// tuple elements.
    struct ExpirationOption: Identifiable, Hashable {
        var id: Int { seconds }
        let seconds: Int
        let title: String
    }

    static let expirationOptions: [ExpirationOption] = [
        ExpirationOption(seconds: 0, title: String(localized: "Never", comment: "Messages never expire")),
        ExpirationOption(seconds: 3600, title: String(localized: "1 hour")),
        ExpirationOption(seconds: 28800, title: String(localized: "8 hours")),
        ExpirationOption(seconds: 86400, title: String(localized: "1 day")),
        ExpirationOption(seconds: 604800, title: String(localized: "1 week")),
        ExpirationOption(seconds: 2419200, title: String(localized: "4 weeks"))
    ]

    func copyLink() {
        let url = session.account.server.url(path: "/index.php/call/\(conversation.token)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Applies only what actually changed, so a save never sends five requests to set five
    /// things to the values they already had.
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        error = nil

        do throws(TalkError) {
            if name != original.name, canRename {
                try await session.conversations.rename(token: conversation.token, to: name)
            }
            if description != original.description, canEditDescription {
                try await session.conversations.setDescription(description, token: conversation.token)
            }
            if isReadOnly != original.readOnly {
                try await session.conversations.setReadOnly(isReadOnly, token: conversation.token)
            }
            if expiration != original.expiration {
                try await session.conversations.setMessageExpiration(seconds: expiration, token: conversation.token)
            }
            if isPublic != original.isPublic {
                try await session.conversations.setPublic(isPublic, token: conversation.token)
            }
            if !password.isEmpty {
                try await session.conversations.setPassword(password, token: conversation.token)
            }
            if isLobbyOn != originalLobby.isOn || lobbyOpensAt != originalLobby.opensAt, canSetLobby {
                try await session.conversations.setLobby(isLobbyOn, opensAt: lobbyOpensAt, token: conversation.token)
            }
            return true
        } catch {
            self.error = error.userMessage
            return false
        }
    }

    func leave() async -> Bool {
        do throws(TalkError) {
            try await session.participants.leave(token: conversation.token)
            return true
        } catch {
            self.error = error.userMessage
            return false
        }
    }

    func delete() async -> Bool {
        do throws(TalkError) {
            try await session.conversations.delete(token: conversation.token)
            return true
        } catch {
            self.error = error.userMessage
            return false
        }
    }
}
