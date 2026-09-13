import Foundation

/// Every path this client knows. Centralized so the API-version story is visible in one
/// place: conversations are v4, chat/reactions are v1, and core OCS is unversioned.
enum Endpoint {
    static let ocs = "/ocs/v2.php"
    static let spreedV1 = "/ocs/v2.php/apps/spreed/api/v1"
    static let spreedV4 = "/ocs/v2.php/apps/spreed/api/v4"

    // Core
    static let capabilities = "\(ocs)/cloud/capabilities"
    static let user = "\(ocs)/cloud/user"
    static let appPassword = "\(ocs)/core/apppassword"

    // Login Flow v2 — not OCS, and deliberately not under /ocs.
    static let loginFlowStart = "/index.php/login/v2"

    // Conversations (v4)
    static let rooms = "\(spreedV4)/room"
    static func room(_ token: String) -> String { "\(spreedV4)/room/\(token)" }
    static let noteToSelf = "\(spreedV4)/room/note-to-self"
    static func favorite(_ token: String) -> String { "\(spreedV4)/room/\(token)/favorite" }
    static func notify(_ token: String) -> String { "\(spreedV4)/room/\(token)/notify" }
    static func participants(_ token: String) -> String { "\(spreedV4)/room/\(token)/participants" }
    static func activeParticipants(_ token: String) -> String { "\(spreedV4)/room/\(token)/participants/active" }
    static func sessionState(_ token: String) -> String { "\(spreedV4)/room/\(token)/participants/state" }
    static func conversationAvatar(_ token: String, dark: Bool = false) -> String {
        "\(spreedV1)/room/\(token)/avatar" + (dark ? "/dark" : "")
    }

    // Chat (v1)
    static func chat(_ token: String) -> String { "\(spreedV1)/chat/\(token)" }
    static func chatMessage(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/chat/\(token)/\(messageID)" }
    static func chatReadMarker(_ token: String) -> String { "\(spreedV1)/chat/\(token)/read" }
    static func chatContext(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/chat/\(token)/\(messageID)/context" }
    static func mentions(_ token: String) -> String { "\(spreedV1)/chat/\(token)/mentions" }
    static func reaction(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/reaction/\(token)/\(messageID)" }

    // Avatars (not OCS)
    static func userAvatar(_ userID: String, size: Int, dark: Bool = false) -> String {
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        return "/index.php/avatar/\(encoded)/\(size)" + (dark ? "/dark" : "")
    }
}
