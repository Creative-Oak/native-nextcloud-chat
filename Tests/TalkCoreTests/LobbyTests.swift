import Foundation
import Testing
@testable import TalkCore

struct LobbyTests {
    @Test func aLobbyHoldsOrdinaryParticipants() {
        #expect(Conversation(token: "t", participantType: .user, lobbyState: 1).isLobbyBlocking)
        #expect(Conversation(token: "t", participantType: .guest, lobbyState: 1).isLobbyBlocking)
    }

    @Test func moderatorsAreNeverHeld() {
        #expect(!Conversation(token: "t", participantType: .moderator, lobbyState: 1).isLobbyBlocking)
        #expect(!Conversation(token: "t", participantType: .owner, lobbyState: 1).isLobbyBlocking)
    }

    @Test func thoseAllowedToSkipItAreNotHeld() {
        let skipping = Conversation(token: "t", participantType: .user, permissions: [.custom, .ignoreLobby, .postMessages], lobbyState: 1)
        #expect(!skipping.isLobbyBlocking)
    }

    @Test func noLobbyHoldsNobody() {
        #expect(!Conversation(token: "t", participantType: .user, lobbyState: 0).isLobbyBlocking)
    }

    @Test func onlyGroupsAndPublicConversationsHaveALobby() {
        #expect(Conversation(token: "t", type: .group).supportsLobby)
        #expect(Conversation(token: "t", type: .publicRoom).supportsLobby)
        #expect(!Conversation(token: "t", type: .oneToOne).supportsLobby)
        #expect(!Conversation(token: "t", type: .noteToSelf).supportsLobby)
    }
}
