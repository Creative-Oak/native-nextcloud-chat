import Foundation
import Testing
@testable import TalkCore

@Suite("Typing indicators")
struct TypingTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func tracker() -> TypingTracker {
        var tracker = TypingTracker()
        tracker.ownSessionID = "me"
        tracker.ownUserID = "magnus"
        tracker.joined([
            RoomSession(signalingID: "me", userID: "magnus", displayName: "Magnus"),
            RoomSession(signalingID: "phone", userID: "magnus", displayName: "Magnus"),
            RoomSession(signalingID: "h1", userID: "heine", displayName: "Heine"),
            RoomSession(signalingID: "h2", userID: "heine", displayName: "Heine"),
            RoomSession(signalingID: "g", displayName: nil),
        ])
        return tracker
    }

    @Test("Typing messages and join and leave events decode, and a typing signal encodes as Talk sends it")
    func protocolMessages() throws {
        func decode(_ json: String) -> SignalingInbound? { SignalingInbound.decode(Data(json.utf8)) }
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":{"type":"startedTyping","to":"me"}}}"#) == .typing(fromSession: "s1", isTyping: true))
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":{"type":"stoppedTyping"}}}"#) == .typing(fromSession: "s1", isTyping: false))
        #expect(decode(#"{"type":"event","event":{"target":"room","type":"join","join":[{"sessionid":"s1","userid":"heine","roomsessionid":"n1","user":{"displayname":"Heine"}},{"sessionid":"s2","userid":"","user":{}}]}}"#)
            == .sessionsJoined([
                RoomSession(signalingID: "s1", nextcloudSessionID: "n1", userID: "heine", displayName: "Heine"),
                RoomSession(signalingID: "s2"),
            ]))
        #expect(decode(#"{"type":"event","event":{"target":"room","type":"leave","leave":["s1"]}}"#) == .sessionsLeft(["s1"]))

        let data = SignalingOutbound.message(toSession: "s1", data: ["type": "startedTyping", "to": "s1"]).encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        #expect(object["type"] as? String == "message")
        #expect((message["recipient"] as? [String: String]) == ["type": "session", "sessionid": "s1"])
        #expect((message["data"] as? [String: String])?["type"] == "startedTyping")
    }

    @Test("Someone typing shows once however many devices, never yourself, and wears off after 15 seconds")
    func typists() {
        var tracker = tracker()
        tracker.received(fromSession: "h1", isTyping: true, at: now)
        tracker.received(fromSession: "h2", isTyping: true, at: now)
        tracker.received(fromSession: "phone", isTyping: true, at: now)
        tracker.received(fromSession: "stranger", isTyping: true, at: now)
        #expect(tracker.typists(at: now).map(\.displayName) == ["Heine"])
        #expect(tracker.typists(at: now.addingTimeInterval(14)).count == 1)
        #expect(tracker.typists(at: now.addingTimeInterval(15)).isEmpty)
        #expect(tracker.nextExpiry(after: now) == now.addingTimeInterval(15))
        #expect(tracker.nextExpiry(after: now.addingTimeInterval(15)) == nil)
    }

    @Test("Stopping, leaving and switching conversation each take someone off")
    func stopping() {
        var tracker = tracker()
        tracker.received(fromSession: "h1", isTyping: true, at: now)
        tracker.received(fromSession: "g", isTyping: true, at: now)
        #expect(tracker.typists(at: now).count == 2)
        tracker.received(fromSession: "g", isTyping: false, at: now)
        #expect(tracker.typists(at: now).map(\.userID) == ["heine"])
        tracker.left(["h1"])
        #expect(tracker.typists(at: now).isEmpty)
        #expect(tracker.recipients == ["g", "h2", "phone"])
        tracker.reset()
        #expect(tracker.recipients.isEmpty)
    }

    @Test("The summary names up to three people, as Talk does")
    func summary() {
        #expect(TypingSummary.text(names: []) == nil)
        #expect(TypingSummary.text(names: ["Heine"]) == "Heine is typing…")
        #expect(TypingSummary.text(names: [nil]) == "Someone is typing…")
        #expect(TypingSummary.text(names: ["Heine", "Lea"]) == "Heine and Lea are typing…")
        #expect(TypingSummary.text(names: ["A", "B", "C"]) == "A, B and C are typing…")
        #expect(TypingSummary.text(names: ["A", "B", "C", "D"]) == "A, B, C and 1 other are typing…")
        #expect(TypingSummary.text(names: ["A", nil, nil]) == "A and 2 others are typing…")
    }
}
