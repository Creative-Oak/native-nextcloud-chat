import AppKit
import SwiftUI

/// Moderator settings for a conversation.
///
/// Only the things a chat client needs: what it's called, what it says it's for, whether
/// anyone can post, whether messages expire, and how to get out. Everything else Talk can
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
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasChanges || model.isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 520)
        .background(.regularMaterial)
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
    var isConfirmingDelete = false

    private(set) var isSaving = false
    private(set) var error: String?

    let conversation: Conversation
    private let session: Session
    private let original: (name: String, description: String, readOnly: Bool, isPublic: Bool, expiration: Int)

    init(session: Session, conversation: Conversation) {
        self.session = session
        self.conversation = conversation
        self.token = conversation.token
        self.name = conversation.name
        self.description = conversation.description
        self.isReadOnly = conversation.isReadOnly
        self.isPublic = conversation.isPublic
        self.expiration = conversation.messageExpiration
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

    var hasChanges: Bool {
        name != original.name
            || description != original.description
            || isReadOnly != original.readOnly
            || isPublic != original.isPublic
            || expiration != original.expiration
            || !password.isEmpty
    }

    /// A struct, not a tuple: `ForEach(_:id:)` needs a key path and Swift has none into
    /// tuple elements.
    struct ExpirationOption: Identifiable, Hashable {
        var id: Int { seconds }
        let seconds: Int
        let title: String
    }

    static let expirationOptions: [ExpirationOption] = [
        ExpirationOption(seconds: 0, title: "Never"),
        ExpirationOption(seconds: 3600, title: "1 hour"),
        ExpirationOption(seconds: 28800, title: "8 hours"),
        ExpirationOption(seconds: 86400, title: "1 day"),
        ExpirationOption(seconds: 604800, title: "1 week"),
        ExpirationOption(seconds: 2419200, title: "4 weeks")
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
