import Foundation

/// A piece of WebRTC negotiation, carried over the signaling server between this client and
/// the media server (Janus, behind the High Performance Backend). With a media server every
/// client sends its own media once — an offer to its own session — and receives each other
/// publisher's by asking their session for an offer. See the signaling API, "Media publishing".
struct CallSignal: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case offer(sdp: String)
        case answer(sdp: String)
        case candidate(IceCandidate)
        /// Ask a publisher's session for an offer of what it sends.
        case requestOffer
        /// Which of a publisher's simulcast layers the media server should pass on: 0 lowest,
        /// 2 best — spatially and in frame rate.
        case selectStream(substream: Int, temporal: Int)
        /// Have the media server offer this client's screen to a session. The receiving side
        /// can't know a screen is being shared, so the one sharing sets it off.
        case sendOffer
        /// The screen isn't being shared any more. To the whole room.
        case unshareScreen
    }

    var kind: Kind
    /// The negotiation this belongs to: chosen by whoever made the offer, and repeated on
    /// everything after it.
    var sid: String?
    /// `video` for the camera and microphone, `screen` for a shared screen.
    var roomType = "video"

    /// The `data` of the message, addressed to `session`.
    func data(to session: String, nick: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["to": session, "roomType": roomType]
        if let sid { data["sid"] = sid }
        switch kind {
        case .offer(let sdp):
            data["type"] = "offer"
            var payload: [String: Any] = ["type": "offer", "sdp": sdp]
            if let nick { payload["nick"] = nick }
            data["payload"] = payload
        case .answer(let sdp):
            data["type"] = "answer"
            var payload: [String: Any] = ["type": "answer", "sdp": sdp]
            if let nick { payload["nick"] = nick }
            data["payload"] = payload
        case .candidate(let candidate):
            data["type"] = "candidate"
            var inner: [String: Any] = ["candidate": candidate.candidate, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
            if let mid = candidate.sdpMid { inner["sdpMid"] = mid }
            data["payload"] = ["candidate": inner]
        case .requestOffer:
            data["type"] = "requestoffer"
        case .selectStream(let substream, let temporal):
            data["type"] = "selectStream"
            data["payload"] = ["substream": substream, "temporal": temporal]
        case .sendOffer:
            data["type"] = "sendoffer"
        case .unshareScreen:
            data["type"] = "unshareScreen"
        }
        return data
    }

    /// A signal from a message's `data`; nil for anything that isn't one.
    static func decode(_ data: [String: Any]) -> CallSignal? {
        let payload = data["payload"] as? [String: Any] ?? [:]
        let sid = data["sid"] as? String
        let roomType = data["roomType"] as? String ?? "video"
        let kind: Kind
        switch data["type"] as? String {
        case "offer":
            guard let sdp = payload["sdp"] as? String else { return nil }
            kind = .offer(sdp: sdp)
        case "answer":
            guard let sdp = payload["sdp"] as? String else { return nil }
            kind = .answer(sdp: sdp)
        case "candidate":
            let inner = payload["candidate"] as? [String: Any] ?? [:]
            // The API's own documentation spells it "candiate"; the servers send "candidate".
            guard let text = inner["candidate"] as? String ?? inner["candiate"] as? String else { return nil }
            let index = (inner["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
            kind = .candidate(IceCandidate(candidate: text, sdpMid: inner["sdpMid"] as? String, sdpMLineIndex: index))
        case "requestoffer":
            kind = .requestOffer
        case "unshareScreen":
            kind = .unshareScreen
        default:
            return nil
        }
        return CallSignal(kind: kind, sid: sid, roomType: roomType)
    }
}

struct IceCandidate: Sendable, Equatable {
    var candidate: String
    var sdpMid: String?
    var sdpMLineIndex: Int32
}

/// A STUN or TURN server for getting media through firewalls, from the signaling settings.
struct IceServerConfig: Sendable, Equatable {
    var urls: [String]
    var username: String?
    var credential: String?
}

/// What a participant is doing in the call — Talk's in-call flags.
struct CallFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let inCall = CallFlags(rawValue: 1)
    static let withAudio = CallFlags(rawValue: 2)
    static let withVideo = CallFlags(rawValue: 4)
    static let withPhone = CallFlags(rawValue: 8)

    /// Whether they send anything there is to receive.
    var isPublishing: Bool { contains(.inCall) && !intersection([.withAudio, .withVideo, .withPhone]).isEmpty }
}

/// One session's state in the conversation, from the signaling server's participants update.
struct CallParticipantState: Sendable, Equatable {
    /// The signaling server's id — what media is requested from.
    var sessionID: String
    var nextcloudSessionID: String?
    var flags: CallFlags
    var userID: String?
    var actorType: String?
    var actorID: String?
    var displayName: String?

    init(sessionID: String, nextcloudSessionID: String? = nil, flags: CallFlags, userID: String? = nil,
         actorType: String? = nil, actorID: String? = nil, displayName: String? = nil) {
        self.sessionID = sessionID
        self.nextcloudSessionID = nextcloudSessionID
        self.flags = flags
        self.userID = userID
        self.actorType = actorType
        self.actorID = actorID
        self.displayName = displayName
    }

    init?(json: [String: Any]) {
        guard let session = json["sessionId"] as? String, !session.isEmpty else { return nil }
        func text(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            sessionID: session,
            nextcloudSessionID: text("nextcloudSessionId"),
            flags: CallFlags(rawValue: (json["inCall"] as? NSNumber)?.intValue ?? 0),
            userID: text("userId"),
            actorType: text("actorType"),
            actorID: text("actorId"),
            displayName: text("displayName")
        )
    }
}

/// Who else is in the call, from the signaling server's participant updates, and what that
/// means for the media: whose to ask for, and whose to let go of.
struct CallRoster: Sendable {
    let ownSessionID: String
    private(set) var inCall: [String: CallParticipantState] = [:]

    init(ownSessionID: String) {
        self.ownSessionID = ownSessionID
    }

    struct Change: Sendable, Equatable {
        /// Now sending something, and not asked for yet.
        var toSubscribe: [CallParticipantState] = []
        /// Gone from the call.
        var toDrop: [String] = []
    }

    /// An update lists the participants that changed; anyone in it not in the call has left.
    mutating func apply(_ users: [CallParticipantState]) -> Change {
        var change = Change()
        for user in users where user.sessionID != ownSessionID {
            let was = inCall[user.sessionID]
            if user.flags.contains(.inCall) {
                inCall[user.sessionID] = user
                if user.flags.isPublishing, !(was?.flags.isPublishing ?? false) {
                    change.toSubscribe.append(user)
                }
            } else if was != nil {
                inCall[user.sessionID] = nil
                change.toDrop.append(user.sessionID)
            }
        }
        return change
    }

    /// Sessions that left the conversation altogether.
    mutating func left(_ sessionIDs: [String]) -> Change {
        var change = Change()
        for id in sessionIDs where inCall.removeValue(forKey: id) != nil {
            change.toDrop.append(id)
        }
        return change
    }

    /// The call ended for everyone at once.
    mutating func ended() -> Change {
        let change = Change(toDrop: Array(inCall.keys).sorted())
        inCall = [:]
        return change
    }
}

/// What a participant says about their own media — on the data channel named "status", and
/// as `mute`/`unmute` messages through the signaling server, the two ways Talk's clients
/// tell each other; a client may hear either first.
enum MediaStatus: String, Sendable, Equatable {
    case audioOn, audioOff, videoOn, videoOff, speaking, stoppedSpeaking

    /// The data channel message: `{"type": "videoOn"}`.
    var dataChannelMessage: Data {
        (try? JSONSerialization.data(withJSONObject: ["type": rawValue])) ?? Data()
    }

    init?(dataChannelMessage data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        self.init(rawValue: type)
    }

    /// The signaling message's `data`, for the ones that go that way too.
    func signalingData(to session: String) -> [String: Any]? {
        let (type, name): (String, String)
        switch self {
        case .audioOn: (type, name) = ("unmute", "audio")
        case .audioOff: (type, name) = ("mute", "audio")
        case .videoOn: (type, name) = ("unmute", "video")
        case .videoOff: (type, name) = ("mute", "video")
        case .speaking, .stoppedSpeaking: return nil
        }
        return ["to": session, "roomType": "video", "type": type, "payload": ["name": name]]
    }

    /// From a signaling message's `data`.
    init?(signalingData data: [String: Any]) {
        let name = (data["payload"] as? [String: Any])?["name"] as? String
        switch (data["type"] as? String, name) {
        case ("mute", "audio"): self = .audioOff
        case ("unmute", "audio"): self = .audioOn
        case ("mute", "video"): self = .videoOff
        case ("unmute", "video"): self = .videoOn
        default: return nil
        }
    }
}
