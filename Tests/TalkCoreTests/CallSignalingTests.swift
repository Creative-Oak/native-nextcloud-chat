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
        let select = CallSignal(kind: .selectStream(substream: 2, temporal: 2), sid: "x").data(to: "them")
        #expect(select["type"] as? String == "selectStream")
        #expect((select["payload"] as? [String: Int]) == ["substream": 2, "temporal": 2])
        #expect(select["sid"] as? String == "x")

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

    @Test("Media status goes as a data channel message and as mute and unmute, and comes back either way")
    func mediaStatus() throws {
        #expect(MediaStatus(dataChannelMessage: MediaStatus.videoOn.dataChannelMessage) == .videoOn)
        #expect(MediaStatus(dataChannelMessage: Data(#"{"type":"speaking"}"#.utf8)) == .speaking)
        #expect(MediaStatus(dataChannelMessage: Data(#"{"type":"nickChanged","payload":"x"}"#.utf8)) == nil)

        let data = SignalingOutbound.mediaStatus(toSession: "them", .audioOff).encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require((object["message"] as? [String: Any])?["data"] as? [String: Any])
        #expect(body["type"] as? String == "mute")
        #expect((body["payload"] as? [String: String]) == ["name": "audio"])
        #expect(MediaStatus.speaking.signalingData(to: "them") == nil)

        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":{"type":"unmute","roomType":"video","payload":{"name":"video"}}}}"#)
            == .mediaStatus(fromSession: "s1", .videoOn))
    }

    @Test("Screen sharing: an offer set off for a session, and the end told to the whole room")
    func screenSharing() throws {
        let offer = CallSignal(kind: .sendOffer, roomType: "screen").data(to: "them")
        #expect(offer["type"] as? String == "sendoffer")
        #expect(offer["roomType"] as? String == "screen")

        let data = SignalingOutbound.roomCallSignal(CallSignal(kind: .unshareScreen, roomType: "screen")).encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        #expect((message["recipient"] as? [String: String]) == ["type": "room"])
        let body = try #require(message["data"] as? [String: Any])
        #expect(body["type"] as? String == "unshareScreen")
        #expect(body["to"] == nil)

        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":{"roomType":"screen","type":"unshareScreen"}}}"#)
            == .callSignal(fromSession: "s1", CallSignal(kind: .unshareScreen, roomType: "screen")))
        #expect(decode(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":{"type":"offer","roomType":"screen","sid":"z","payload":{"type":"offer","sdp":"v=0"}}}}"#)
            == .callSignal(fromSession: "s1", CallSignal(kind: .offer(sdp: "v=0"), sid: "z", roomType: "screen")))
    }

    @Test("Raised hands, reactions and forced mutes go as Talk's web app sends them, and come back")
    func callMessages() throws {
        func sent(_ message: CallMessage) throws -> [String: Any] {
            let object = try JSONSerialization.jsonObject(with: SignalingOutbound.callMessage(toSession: "s2", message).encoded()) as? [String: Any]
            return ((object?["message"] as? [String: Any])?["data"] as? [String: Any]) ?? [:]
        }
        let hand = try sent(.raiseHand(true, at: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(hand["type"] as? String == "raiseHand")
        #expect(hand["to"] as? String == "s2")
        #expect((hand["payload"] as? [String: Any])?["state"] as? Bool == true)
        #expect((hand["payload"] as? [String: Any])?["timestamp"] as? Int == 1_700_000_000_000)
        #expect(((try sent(.reaction("👏")))["payload"] as? [String: Any])?["reaction"] as? String == "👏")
        // A forced mute goes as a control, not a message, the way the web app sends it.
        let control = try JSONSerialization.jsonObject(with: SignalingOutbound.callMessage(toSession: "s2", .forceMute(target: "s9")).encoded()) as? [String: Any]
        #expect(control?["type"] as? String == "control")
        let body = control?["control"] as? [String: Any]
        #expect((body?["recipient"] as? [String: Any])?["sessionid"] as? String == "s2")
        #expect((body?["data"] as? [String: Any])?["action"] as? String == "forceMute")
        // A type too, or Talk for iOS drops it before reading the action.
        #expect((body?["data"] as? [String: Any])?["type"] as? String == "control")
        #expect((body?["data"] as? [String: Any])?["peerId"] as? String == "s9")

        func received(_ data: String) -> SignalingInbound? {
            SignalingInbound.decode(Data(#"{"type":"message","message":{"sender":{"type":"session","sessionid":"s1"},"data":\#(data)}}"#.utf8))
        }
        #expect(received(#"{"type":"raiseHand","payload":{"state":true,"timestamp":1}}"#) == .raisedHand(fromSession: "s1", isRaised: true))
        #expect(received(#"{"type":"raiseHand","payload":{"state":false}}"#) == .raisedHand(fromSession: "s1", isRaised: false))
        #expect(received(#"{"type":"reaction","payload":{"reaction":"🎉"}}"#) == .callReaction(fromSession: "s1", emoji: "🎉"))
        #expect(received(#"{"type":"control","payload":{"action":"forceMute","peerId":"me"}}"#) == .forceMute(target: "me", fromSession: "s1"))
        // And as Talk's apps send it: a control of its own.
        let fromWeb = SignalingInbound.decode(Data(#"{"type":"control","control":{"sender":{"type":"session","sessionid":"s1"},"data":{"action":"forceMute","peerId":"me"}}}"#.utf8))
        #expect(fromWeb == .forceMute(target: "me", fromSession: "s1"))
    }
}
