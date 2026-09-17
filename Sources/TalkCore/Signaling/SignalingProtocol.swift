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
    /// Someone joined or left the open conversation, or a call started or stopped in it.
    case participantsChanged(token: String)
    /// Something was posted in the open conversation.
    case roomMessage(token: String)
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
        case ("roomlist", "invite") where !token.isEmpty: return .roomList(.added, token: token)
        case ("roomlist", "disinvite") where !token.isEmpty: return .roomList(.removed, token: token)
        case ("roomlist", "update") where !token.isEmpty: return .roomList(.updated, token: token)
        case ("roomlist", "delete") where !token.isEmpty: return .roomList(.deleted, token: token)
        case ("participants", _) where !token.isEmpty: return .participantsChanged(token: token)
        case ("room", "message") where !token.isEmpty: return .roomMessage(token: token)
        default: return .other(type: "event", json: data)
        }
    }
}

enum RoomListChange: Sendable, Equatable {
    case added, removed, updated, deleted
}
