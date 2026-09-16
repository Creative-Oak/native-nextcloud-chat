import Foundation
import Testing
@testable import TalkCore

@Suite("Message decoding")
struct MessageDecodingTests {
    private func messages() throws -> [Message] {
        let envelope = try JSONDecoder().decode(
            OCSEnvelope<[MessageDTO]>.self, from: try Fixture.data("messages")
        )
        return try #require(envelope.data).map { $0.model(token: "a1b2c3d4") }
    }

    private func message(_ id: Int) throws -> Message {
        try #require(try messages().first { $0.messageID == id })
    }

    @Test("Decodes a rich message with a mention, a file, reactions and markdown")
    func richMessage() throws {
        let message = try message(9843)
        #expect(message.actor.id == "bob")
        #expect(message.actor.kind == .users)
        #expect(message.actor.resolvedDisplayName == "Bob Bakker")
        #expect(message.kind == .comment)
        #expect(message.isMarkdown)
        #expect(message.isReplyable)
        #expect(message.reactions == ["👍": 2, "🎉": 1])
        #expect(message.myReactions == ["👍"])
        #expect(message.referenceID == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let mention = try #require(message.parameters["mention-user1"])
        #expect(mention.type == .user)
        #expect(mention.id == "alice")
        #expect(mention.name == "Alice Andersen")

        let file = try #require(message.parameters["file"])
        #expect(file.type == .file)
        #expect(file.name == "budget-2026.xlsx")
        #expect(file.size == 18422)               // arrived as a JSON number, stored as a string
        #expect(file.previewAvailable == false)
        #expect(file.link?.absoluteString == "https://cloud.example.com/f/5512")
        #expect(message.isFileShare)
        #expect(message.localID == "a1b2c3d4#9843")
    }

    @Test("An edited reply keeps both the edit metadata and the parent")
    func editedReply() throws {
        let message = try message(9842)
        let edit = try #require(message.lastEdit)
        #expect(edit.actor.id == "alice")
        #expect(edit.timestamp == Date(timeIntervalSince1970: 1757699950))

        let parent = try #require(message.parent)
        #expect(parent.messageID == 9840)
        #expect(parent.actor.resolvedDisplayName == "Bob Bakker")
        #expect(parent.text == "Could someone take the budget?")
        #expect(parent.isDeleted == false)
    }

    @Test("A tombstone is a message, not a hole in the list")
    func deletedMessage() throws {
        let message = try message(9841)
        #expect(message.kind == .commentDeleted)
        #expect(message.isDeleted)
        #expect(message.isDeletable == false)
        #expect(message.actor.isDeletedUser)
        #expect(message.actor.resolvedDisplayName == "Deleted user")
        #expect(message.isVisible)     // shown as "message deleted", not hidden
    }

    @Test("System messages are recognised and the cache-only ones stay hidden")
    func systemMessages() throws {
        let userAdded = try message(9839)
        #expect(userAdded.isSystem)
        #expect(userAdded.systemMessage == "user_added")
        #expect(userAdded.isVisible)

        let cacheOnly = Message(
            messageID: 1, token: "t", actor: MessageActor(kind: .users, id: "a"),
            timestamp: .now, kind: .system, systemMessage: "message_deleted", text: ""
        )
        #expect(cacheOnly.isVisible == false)
    }

    @Test("`@all` arrives as a call object, not a user")
    func mentionCall() throws {
        let message = try message(9838)
        let mention = try #require(message.parameters["mention-call"])
        #expect(mention.type == .call)
        #expect(mention.callType == "group")
        #expect(message.isSilent)
    }

    @Test("Bot messages and open-graph previews decode")
    func botMessage() throws {
        let message = try message(9837)
        #expect(message.actor.isBot)
        #expect(message.actor.resolvedDisplayName == "Talk updates ✅")
        let preview = try #require(message.parameters["open-graph"])
        #expect(preview.type == .openGraph)
        #expect(preview.attributes["website"] == "nextcloud.com")
    }

    @Test("An unknown rich-object type is preserved rather than dropped")
    func unknownRichObject() throws {
        let message = try message(9836)
        let object = try #require(message.parameters["object"])
        #expect(object.type == .other("some-future-type"))
        #expect(object.name == "A thing from a newer server")
    }

    @Test("`messageParameters: []` and `reactions: []` decode as empty, not as errors")
    func emptyCollections() throws {
        let message = try message(9841)
        #expect(message.parameters.isEmpty)
        #expect(message.reactions.isEmpty)
        #expect(message.myReactions.isEmpty)
    }

    @Test("A guest with no display name still gets a usable name")
    func anonymousGuest() {
        let guest = MessageActor(type: "guests", id: "sha1hash", displayName: "")
        #expect(guest.resolvedDisplayName == "Guest")
    }

    @Test("Federated actors expose their home server")
    func federatedActor() {
        let actor = MessageActor(type: "federated_users", id: "frank@other.example.com", displayName: "Frank")
        #expect(actor.isFederated)
        #expect(actor.federationServer == "other.example.com")
    }

    @Test("A private reply is offered to someone else's message in a group, and nowhere else")
    func privateReplyRules() {
        let group = Conversation(token: "g", type: .group)
        let dm = Conversation(token: "d", type: .oneToOne)
        func message(from actor: MessageActor, replyable: Bool = true) -> Message {
            Message(messageID: 7, token: "g", actor: actor, timestamp: Date(), text: "hi", isReplyable: replyable)
        }
        let bob = MessageActor(kind: .users, id: "bob", displayName: "Bob")

        #expect(message(from: bob).canBeRepliedToPrivately(in: group, myUserID: "alice"))
        #expect(!message(from: bob).canBeRepliedToPrivately(in: dm, myUserID: "alice"))
        #expect(!message(from: bob).canBeRepliedToPrivately(in: group, myUserID: "bob"))
        #expect(!message(from: bob, replyable: false).canBeRepliedToPrivately(in: group, myUserID: "alice"))
        let guest = MessageActor(kind: .guests, id: "g1", displayName: "Guest")
        #expect(!message(from: guest).canBeRepliedToPrivately(in: group, myUserID: "alice"))
    }
}
