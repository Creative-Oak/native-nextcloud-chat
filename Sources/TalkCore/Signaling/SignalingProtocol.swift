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
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

enum SignalingInbound: Sendable, Equatable {
    case welcome(features: [String])
    case hello(id: String?, sessionID: String, resumeID: String?, userID: String?)
    case error(id: String?, code: String, message: String)
    case bye
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
        default:
            return .other(type: type, json: data)
        }
    }
}
