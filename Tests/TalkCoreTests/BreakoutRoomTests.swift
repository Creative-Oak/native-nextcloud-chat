import Foundation
import Testing
@testable import TalkCore

struct BreakoutRoomTests {
    private func decode(_ json: String) throws -> Conversation {
        try JSONDecoder().decode(ConversationDTO.self, from: Data(json.utf8)).model()
    }

    @Test func aHostSaysHowItsRoomsRun() throws {
        let host = try decode(#"{"id":1,"token":"main","type":2,"name":"Class","breakoutRoomMode":3,"breakoutRoomStatus":1}"#)
        #expect(host.breakoutRoomMode == .free)
        #expect(host.hasBreakoutRooms)
        #expect(host.areBreakoutRoomsRunning)
        #expect(!host.isBreakoutRoom)
        #expect(host.canHostBreakoutRooms)
    }

    @Test func aBreakoutRoomKnowsItsHost() throws {
        let room = try decode(#"{"id":2,"token":"r1","type":2,"name":"Room 1","objectType":"room","objectId":"main","breakoutRoomStatus":2}"#)
        #expect(room.isBreakoutRoom)
        #expect(room.breakoutParentToken == "main")
        #expect(room.breakoutRoomStatus == .assistanceRequested)
        #expect(!room.canHostBreakoutRooms)
    }

    @Test func withoutTheFieldsNothingIsSetUp() throws {
        let plain = try decode(#"{"id":3,"token":"t","type":2,"name":"Plain"}"#)
        #expect(plain.breakoutRoomMode == .notConfigured)
        #expect(!plain.hasBreakoutRooms)
        #expect(!plain.areBreakoutRoomsRunning)
        #expect(!plain.isBreakoutRoom)
    }

    @Test func aConversationCachedBeforeBreakoutRoomsStillOpens() throws {
        // What the cache holds for a conversation saved before these fields existed.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Conversation(token: "t"))) as? [String: Any] ?? [:]
        old.removeValue(forKey: "breakoutModeValue")
        old.removeValue(forKey: "breakoutStatusValue")
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.breakoutRoomMode == .notConfigured)
    }

    @Test func oneToOnesCantHostThem() {
        #expect(!Conversation(token: "t", type: .oneToOne).canHostBreakoutRooms)
    }

    @Test func breakoutRoomsStayOutOfTheSidebarAndTheBadge() {
        var room = Conversation(token: "r1", type: .group, displayName: "Room 1", objectType: "room", objectID: "main")
        room.unreadMessages = 4
        room.unreadMention = true
        var main = Conversation(token: "main", type: .group, displayName: "Class")
        main.unreadMessages = 1
        let index = ConversationIndex([room, main])
        #expect(ConversationIndex.sections(for: index.allConversations).flatMap(\.items).map(\.token) == ["main"])
        #expect(index.totalUnreadCount == 1)
        #expect(!index.hasUnreadMention)
        // Still there to be opened from the conversation it belongs to.
        #expect(index["r1"] != nil)
    }
}
