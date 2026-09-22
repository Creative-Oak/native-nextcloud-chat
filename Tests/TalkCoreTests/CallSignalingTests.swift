import Foundation
import Testing
@testable import TalkCore

@Suite("Call signaling")
struct CallSignalingTests {
    private func decode(_ json: String) -> SignalingInbound? { SignalingInbound.decode(Data(json.utf8)) }

    @Test("An offer to the own session encodes as the media server expects it")
    func encodesOffer() throws {
        let signal = CallSignal(kind: .offer(sdp: "v=0"), sid: "s1")
        let data = SignalingOutbound.callSignal(toSession: "me", signal, nick: "Magnus").encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        let body = try #require(message["data"] as? [String: Any])
        #expect(object["type"] as? String == "message")
        #expect((message["recipient"] as? [String: String]) == ["type": "session", "sessionid": "me"])
        #expect(body["to"] as? String == "me")
        #expect(body["type"] as? String == "offer")
        #expect(body["sid"] as? String == "s1")
        #expect(body["roomType"] as? String == "video")
        #expect((body["payload"] as? [String: String]) == ["type": "offer", "sdp": "v=0", "nick": "Magnus"])
    }

    @Test("A request for an offer, and a candidate, encode too")
    func encodesRequestAndCandidate() throws {
        let request = CallSignal(kind: .requestOffer).data(to: "them")
        #expect(request["type"] as? String == "requestoffer")
        #expect(request["roomType"] as? String == "video")

        let candidate = CallSignal(kind: .candidate(IceCandidate(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)), sid: "s1").data(to: "me")
        let inner = try #require((candidate["payload"] as? [String: Any])?["candidate"] as? [String: Any])
        #expect(inner["candidate"] as? String == "candidate:1")
        #expect(inner["sdpMid"] as? String == "0")
        #expect(inner["sdpMLineIndex"] as? Int == 0)
    }

    @Test("Offers, answers and candidates from a session decode")
    func decodesSignals() {
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"pub"},"data":{"from":"pub","to":"me","type":"offer","roomType":"video","sid":"x","payload":{"type":"offer","sdp":"v=0"}}}}"#)
            == .callSignal(fromSession: "pub", CallSignal(kind: .offer(sdp: "v=0"), sid: "x")))
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"me"},"data":{"type":"answer","roomType":"video","sid":"y","payload":{"type":"answer","sdp":"v=1"}}}}"#)
            == .callSignal(fromSession: "me", CallSignal(kind: .answer(sdp: "v=1"), sid: "y")))
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"me"},"data":{"type":"candidate","sid":"y","payload":{"candidate":{"candidate":"c","sdpMLineIndex":1,"sdpMid":"1"}}}}}"#)
            == .callSignal(fromSession: "me", CallSignal(kind: .candidate(IceCandidate(candidate: "c", sdpMid: "1", sdpMLineIndex: 1)), sid: "y")))
    }

    @Test("A participants update carries who is in the call, and the everyone-at-once form")
    func decodesParticipants() {
        let update = decode(#"{"type":"event","event":{"target":"participants","type":"update","update":{"roomid":"abc","users":[{"sessionId":"s1","nextcloudSessionId":"n1","inCall":3,"userId":"heine","actorType":"users","actorId":"heine"},{"inCall":1}]}}}"#)
        #expect(update == .participantsChanged(token: "abc", users: [
            CallParticipantState(sessionID: "s1", nextcloudSessionID: "n1", flags: [.inCall, .withAudio], userID: "heine", actorType: "users", actorID: "heine"),
        ], everyone: nil))
        #expect(decode(#"{"type":"event","event":{"target":"participants","type":"update","update":{"roomid":"abc","incall":0,"all":true}}}"#)
            == .participantsChanged(token: "abc", users: [], everyone: CallFlags(rawValue: 0)))
    }

    @Test("The roster asks for media once a participant sends some, and lets go when they leave")
    func roster() {
        var roster = CallRoster(ownSessionID: "me")
        let joined = roster.apply([
            CallParticipantState(sessionID: "me", flags: [.inCall, .withAudio]),
            CallParticipantState(sessionID: "a", flags: [.inCall, .withAudio]),
            CallParticipantState(sessionID: "b", flags: [.inCall]),
            CallParticipantState(sessionID: "c", flags: []),
        ])
        #expect(joined.toSubscribe.map(\.sessionID) == ["a"])
        #expect(joined.toDrop.isEmpty)

        // Already asked for: not again. Starting to send: now.
        #expect(roster.apply([CallParticipantState(sessionID: "a", flags: [.inCall, .withAudio, .withVideo])]).toSubscribe.isEmpty)
        #expect(roster.apply([CallParticipantState(sessionID: "b", flags: [.inCall, .withAudio])]).toSubscribe.map(\.sessionID) == ["b"])

        #expect(roster.apply([CallParticipantState(sessionID: "a", flags: [])]).toDrop == ["a"])
        #expect(roster.left(["b", "zzz"]).toDrop == ["b"])
        _ = roster.apply([CallParticipantState(sessionID: "d", flags: [.inCall, .withAudio])])
        #expect(roster.ended().toDrop == ["d"])
        #expect(roster.inCall.isEmpty)
    }

    @Test("STUN and TURN servers come from the signaling settings")
    func iceServers() throws {
        let json = #"{"signalingMode":"external","server":"https://sig.example.com","stunservers":[{"urls":["stun:stun.example.com:443"]}],"turnservers":[{"urls":["turn:turn.example.com:443?transport=udp"],"username":"u","credential":"p"}]}"#
        let settings = try JSONDecoder().decode(SignalingSettingsDTO.self, from: Data(json.utf8)).model()
        #expect(settings.iceServers == [
            IceServerConfig(urls: ["stun:stun.example.com:443"]),
            IceServerConfig(urls: ["turn:turn.example.com:443?transport=udp"], username: "u", credential: "p"),
        ])
    }
}
