import Foundation

/// The messages of the High Performance Backend's signaling protocol that kvidr speaks —
/// `docs/standalone-signaling-api-v1.md` in `nextcloud-spreed-signaling`. Each is a JSON
/// object whose `type` names the key holding its body.
enum SignalingOutbound: Sendable, Equatable {
    /// A fresh sign-in.
    case hello(id: String, version: String, authURL: URL, params: [String: String], features: [String])
    /// Picking a dropped session back up, without signing in again.
    case resume(id: String, resumeID: String)
    /// Leaving for good, so the server can let the session go.
    case bye(id: String)
    /// Joins a conversation on the signaling server, with the session Nextcloud gave for it —
    /// or, with an empty `roomID`, leaves the one it is in.
    case room(id: String, roomID: String, sessionID: String)
    /// A message straight to one session, with no id: the server answers these only with an
    /// error. Talk's typing signals travel this way, one to each session in the conversation.
    case message(toSession: String, data: [String: String])
    /// WebRTC negotiation for a call, to a session — this client's own, for what it sends.
    case callSignal(toSession: String, CallSignal, nick: String?)
    /// This client's microphone or camera went on or off, told to one session.
    case mediaStatus(toSession: String, MediaStatus)

    func encoded() -> Data {
        let object: [String: Any]
        switch self {
        case let .hello(id, version, authURL, params, features):
            object = [
                "id": id, "type": "hello",
                "hello": [
                    "version": version,
                    "features": features,
                    "auth": ["url": authURL.absoluteString, "params": params]
                ] as [String: Any]
            ]
        case let .resume(id, resumeID):
            object = ["id": id, "type": "hello", "hello": ["version": "2.0", "resumeid": resumeID]]
        case let .bye(id):
            object = ["id": id, "type": "bye", "bye": [String: String]()]
        case let .room(id, roomID, sessionID):
            object = ["id": id, "type": "room", "room": ["roomid": roomID, "sessionid": sessionID]]
        case let .callSignal(session, signal, nick):
            object = ["type": "message", "message": ["recipient": ["type": "session", "sessionid": session], "data": signal.data(to: session, nick: nick)] as [String: Any]]
        case let .mediaStatus(session, status):
            object = ["type": "message", "message": ["recipient": ["type": "session", "sessionid": session], "data": status.signalingData(to: session) ?? [:]] as [String: Any]]
        case let .message(session, data):
            object = ["type": "message", "message": ["recipient": ["type": "session", "sessionid": session], "data": data] as [String: Any]]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

enum SignalingInbound: Sendable, Equatable {
    case welcome(features: [String])
    case hello(id: String?, sessionID: String, resumeID: String?, userID: String?)
    case error(id: String?, code: String, message: String)
    case bye
    /// The conversation this session is in now — the answer to a join, or the server moving it.
    case room(roomID: String)
    /// A conversation the user is in changed, or they were added to or removed from one.
    case roomList(RoomListChange, token: String)
    /// Someone joined or left the open conversation, or a call started or stopped in it: the
    /// participants that changed, or — the call ended for everyone — `everyone` with the flags.
    case participantsChanged(token: String, users: [CallParticipantState], everyone: CallFlags?)
    /// WebRTC negotiation for a call, from a session.
    case callSignal(fromSession: String, CallSignal)
    /// A session's microphone or camera went on or off.
    case mediaStatus(fromSession: String, MediaStatus)
    /// Something was posted in the open conversation.
    case roomMessage(token: String)
    /// Sessions that are in the open conversation on the signaling server: those that came in
    /// since, and, right after joining it, everyone who was already there.
    case sessionsJoined([RoomSession])
    /// Signaling sessions that left the open conversation.
    case sessionsLeft([String])
    /// Someone in the open conversation started or stopped typing.
    case typing(fromSession: String, isTyping: Bool)
    /// Everything this step doesn't act on yet — room events, chat relays, control messages —
    /// kept whole for the ones that will.
    case other(type: String, json: Data)

    static func decode(_ data: Data) -> SignalingInbound? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let id = object["id"] as? String
        let body = object[type] as? [String: Any] ?? [:]

        switch type {
        case "welcome":
            return .welcome(features: body["features"] as? [String] ?? [])
        case "hello":
            guard let session = body["sessionid"] as? String else { return nil }
            return .hello(id: id, sessionID: session, resumeID: body["resumeid"] as? String, userID: body["userid"] as? String)
        case "error":
            return .error(id: id, code: body["code"] as? String ?? "unknown", message: body["message"] as? String ?? "")
        case "bye":
            return .bye
        case "room":
            return .room(roomID: body["roomid"] as? String ?? "")
        case "event":
            return decodeEvent(body, data: data)
        case "message":
            let payload = body["data"] as? [String: Any] ?? [:]
            let sender = (body["sender"] as? [String: Any])?["sessionid"] as? String ?? ""
            switch payload["type"] as? String {
            case "startedTyping" where !sender.isEmpty: return .typing(fromSession: sender, isTyping: true)
            case "stoppedTyping" where !sender.isEmpty: return .typing(fromSession: sender, isTyping: false)
            case "mute", "unmute":
                guard !sender.isEmpty, let status = MediaStatus(signalingData: payload) else { return .other(type: type, json: data) }
                return .mediaStatus(fromSession: sender, status)
            case "offer", "answer", "candidate":
                guard !sender.isEmpty, let signal = CallSignal.decode(payload) else { return .other(type: type, json: data) }
                return .callSignal(fromSession: sender, signal)
            default: return .other(type: type, json: data)
            }
        default:
            return .other(type: type, json: data)
        }
    }

    private static func decodeEvent(_ event: [String: Any], data: Data) -> SignalingInbound {
        let target = event["target"] as? String ?? ""
        let kind = event["type"] as? String ?? ""
        let body = event[kind] as? [String: Any] ?? [:]
        let token = body["roomid"] as? String ?? ""

        switch (target, kind) {
        case ("room", "join"):
            let entries = event["join"] as? [[String: Any]] ?? []
            return .sessionsJoined(entries.compactMap(RoomSession.init(json:)))
        case ("room", "leave"):
            return .sessionsLeft(event["leave"] as? [String] ?? [])
        case ("roomlist", "invite") where !token.isEmpty: return .roomList(.added, token: token)
        case ("roomlist", "disinvite") where !token.isEmpty: return .roomList(.removed, token: token)
        case ("roomlist", "update") where !token.isEmpty: return .roomList(.updated, token: token)
        case ("roomlist", "delete") where !token.isEmpty: return .roomList(.deleted, token: token)
        case ("participants", _) where !token.isEmpty:
            let users = (body["users"] as? [[String: Any]] ?? []).compactMap(CallParticipantState.init(json:))
            let everyone = (body["all"] as? Bool == true) ? CallFlags(rawValue: (body["incall"] as? NSNumber)?.intValue ?? 0) : nil
            return .participantsChanged(token: token, users: users, everyone: everyone)
        case ("room", "message") where !token.isEmpty: return .roomMessage(token: token)
        default: return .other(type: "event", json: data)
        }
    }
}

/// One session in a conversation on the signaling server.
struct RoomSession: Sendable, Equatable {
    /// The signaling server's id for the session — what messages are addressed to.
    var signalingID: String
    /// Nextcloud's id for the same session, from joining the conversation there.
    var nextcloudSessionID: String?
    /// Empty for guests.
    var userID: String?
    var displayName: String?

    init(signalingID: String, nextcloudSessionID: String? = nil, userID: String? = nil, displayName: String? = nil) {
        self.signalingID = signalingID
        self.nextcloudSessionID = nextcloudSessionID
        self.userID = userID
        self.displayName = displayName
    }

    init?(json: [String: Any]) {
        guard let id = json["sessionid"] as? String, !id.isEmpty else { return nil }
        let user = json["user"] as? [String: Any]
        self.init(
            signalingID: id,
            nextcloudSessionID: (json["roomsessionid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            userID: (json["userid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            displayName: (user?["displayname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

enum RoomListChange: Sendable, Equatable {
    case added, removed, updated, deleted
}
