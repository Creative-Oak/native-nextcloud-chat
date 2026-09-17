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

    @Test("A running call is carried, and whether it has video")
    func ongoingCall() throws {
        let rooms = try conversations()
        #expect(!rooms[0].hasCall)
        #expect(rooms[1].hasCall)
        #expect(!rooms[1].isVideoCall)   // callFlag 3: joined, with audio

        var video = rooms[1]
        video.callFlag = 7
        #expect(video.isVideoCall)
        video.hasCall = false
        #expect(!video.isVideoCall)      // a stale flag is not a call
    }

    @Test("The default notification level is what a one-to-one or a group actually gets")
    func effectiveNotificationLevel() {
        #expect(Conversation(token: "a", type: .oneToOne).effectiveNotificationLevel == .always)
        #expect(Conversation(token: "b", type: .group).effectiveNotificationLevel == .mention)
        #expect(Conversation(token: "c", type: .group, notificationLevel: .never).effectiveNotificationLevel == .never)
        #expect(!Conversation.selectableNotificationLevels.contains(.default))
    }

    @Test("Do Not Disturb silences everything but an important conversation")
    func doNotDisturb() {
        var room = Conversation(token: "t", type: .oneToOne, notificationLevel: .always)
        #expect(room.shouldNotify(forMention: true))
        #expect(!room.shouldNotify(forMention: true, isDoNotDisturb: true))
        room.isImportant = true
        #expect(room.shouldNotify(forMention: false, isDoNotDisturb: true))
        room.notificationLevel = .never
        #expect(!room.shouldNotify(forMention: true, isDoNotDisturb: true))  // off is still off
    }

    @Test("Important and sensitive decode, and a cached conversation from before them still opens")
    func importantAndSensitive() throws {
        let json = #"{"token":"t","isImportant":true,"isSensitive":1,"lastPinnedId":42,"hiddenPinnedId":40}"#
        let room = try JSONDecoder().decode(ConversationDTO.self, from: Data(json.utf8)).model()
        #expect(room.isImportant)
        #expect(room.isSensitive)
        #expect(room.lastPinnedID == 42 && room.hiddenPinnedID == 40)
        #expect(ConversationPreview.text(for: room) == ConversationPreview.hiddenText)

        // Encode a conversation, strip the new keys, and decode it as the cache would.
        let encoded = try JSONEncoder().encode(Conversation(token: "old", displayName: "Old"))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "importantFlag")
        object.removeValue(forKey: "sensitiveFlag")
        object.removeValue(forKey: "lastPinnedValue")
        object.removeValue(forKey: "hiddenPinnedValue")
        let old = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.displayName == "Old")
        #expect(!old.isImportant && !old.isSensitive)
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
