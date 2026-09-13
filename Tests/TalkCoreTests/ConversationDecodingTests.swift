import Foundation
import Testing
@testable import TalkCore

@Suite("Conversation decoding")
struct ConversationDecodingTests {
    private func conversations() throws -> [Conversation] {
        let envelope = try JSONDecoder().decode(
            OCSEnvelope<[ConversationDTO]>.self, from: try Fixture.data("conversations")
        )
        return try #require(envelope.data).map { $0.model() }
    }

    @Test("Decodes every room type in one response")
    func decodesAllRoomTypes() throws {
        let rooms = try conversations()
        #expect(rooms.count == 6)
        #expect(rooms.map(\.type) == [.oneToOne, .group, .noteToSelf, .publicRoom, .formerOneToOne, .group])
    }

    @Test("A one-to-one carries unread state, favourite, and the partner's status")
    func oneToOne() throws {
        let room = try #require(try conversations().first)
        #expect(room.token == "a1b2c3d4")
        #expect(room.displayName == "Bob Bakker")
        #expect(room.isOneToOne)
        #expect(room.oneToOnePartnerID == "bob")
        #expect(room.isFavorite)
        #expect(room.unreadMessages == 3)
        #expect(room.unreadMention)
        #expect(room.unreadMentionDirect)
        #expect(room.lastReadMessageID == 9840)
        #expect(room.lastCommonReadMessageID == 9843)
        #expect(room.userStatus?.status == "online")
        #expect(room.userStatus?.message == "Focusing")
        #expect(room.lastMessage?.messageID == 9843)
        #expect(room.lastMessage?.parameters["file"]?.name == "budget-2026.xlsx")
        #expect(room.canPostMessages)   // permissions 0 == "use the default", i.e. allowed
    }

    @Test("`lastMessage: []` on an empty conversation decodes as no message, not a failure")
    func emptyLastMessage() throws {
        let noteToSelf = try #require(try conversations().first { $0.type == .noteToSelf })
        #expect(noteToSelf.lastMessage == nil)
        #expect(noteToSelf.displayName == "Note to self")
        #expect(noteToSelf.isNoteToSelf)
        #expect(noteToSelf.canLeaveConversation == false)
    }

    @Test("A custom permissions bitmask is honoured")
    func permissionsBitmask() throws {
        let rooms = try conversations()
        let group = try #require(rooms.first { $0.token == "e5f6g7h8" })
        // 127 = custom(1) + start(2) + join(4) + lobby(8) + audio(16) + video(32) + screen(64),
        // and deliberately NOT post(128) — a moderated room where this user may listen but not write.
        #expect(group.permissions.contains(.custom))
        #expect(group.permissions.contains(.publishVideo))
        #expect(group.permissions.contains(.postMessages) == false)
        #expect(group.canPostMessages == false)

        let publicRoom = try #require(rooms.first { $0.token == "m3n4o5p6" })
        // 384 = 128 post + 256 react
        #expect(publicRoom.canPostMessages)
        #expect(publicRoom.canReact)
    }

    @Test("A read-only former one-to-one can be read but not posted to")
    func formerOneToOne() throws {
        let room = try #require(try conversations().first { $0.type == .formerOneToOne })
        #expect(room.isReadOnly)
        #expect(room.canPostMessages == false)
        #expect(room.isOneToOne)     // still rendered as a person, not a group
    }

    @Test("A sparse response from an older server still decodes")
    func sparseConversation() throws {
        let room = try #require(try conversations().first { $0.token == "u1v2w3x4" })
        #expect(room.displayName == "Old server room")
        #expect(room.unreadMentionDirect == false)
        #expect(room.notificationLevel == .default)
        #expect(room.canLeaveConversation)     // documented default when absent
        #expect(room.avatarVersion.isEmpty)
    }

    @Test("Without direct-mention-flag, the coarse mention flag is used for both")
    func mentionFallback() throws {
        let json = ocsEnvelope(#"[{"token":"x","type":2,"unreadMessages":2,"unreadMention":true}]"#)
        let envelope = try JSONDecoder().decode(OCSEnvelope<[ConversationDTO]>.self, from: Data(json.utf8))
        let room = try #require(envelope.data?.first?.model())
        #expect(room.unreadMention)
        #expect(room.unreadMentionDirect)
    }

    @Test("Sidebar order: favourites first, then most recent")
    func sidebarOrdering() throws {
        let sorted = try conversations().sorted(by: Conversation.sidebarSort)
        #expect(sorted.map(\.token) == ["a1b2c3d4", "e5f6g7h8", "i9j0k1l2", "m3n4o5p6", "q7r8s9t0", "u1v2w3x4"])
    }

    @Test("Favourites float even when they're older")
    func favouritesFloat() {
        let old = Conversation(token: "fav", lastActivity: Date(timeIntervalSince1970: 1), isFavorite: true)
        let recent = Conversation(token: "new", lastActivity: Date(timeIntervalSince1970: 100))
        #expect([recent, old].sorted(by: Conversation.sidebarSort).map(\.token) == ["fav", "new"])
    }

    @Test("Notification level decides whether a message raises a notification")
    func notificationPolicy() {
        let always = Conversation(token: "a", type: .group, notificationLevel: .always)
        #expect(always.shouldNotify(forMention: false))

        let mentionsOnly = Conversation(token: "b", type: .group, notificationLevel: .mention)
        #expect(mentionsOnly.shouldNotify(forMention: false) == false)
        #expect(mentionsOnly.shouldNotify(forMention: true))

        let never = Conversation(token: "c", type: .group, notificationLevel: .never)
        #expect(never.shouldNotify(forMention: true) == false)

        // Talk's server-side default: everything in a one-to-one, mentions in a group.
        let defaultOneToOne = Conversation(token: "d", type: .oneToOne)
        #expect(defaultOneToOne.shouldNotify(forMention: false))
        let defaultGroup = Conversation(token: "e", type: .group)
        #expect(defaultGroup.shouldNotify(forMention: false) == false)
        #expect(defaultGroup.shouldNotify(forMention: true))
    }

    @Test("An unknown future room type degrades to a group rather than failing")
    func unknownRoomType() throws {
        let json = ocsEnvelope(#"[{"token":"x","type":99}]"#)
        let envelope = try JSONDecoder().decode(OCSEnvelope<[ConversationDTO]>.self, from: Data(json.utf8))
        #expect(envelope.data?.first?.model().type == .group)
    }
}
