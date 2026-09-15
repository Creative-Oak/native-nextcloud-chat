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

    static func poll(_ token: String) -> String { "\(spreedV1)/poll/\(token)" }
    static func poll(_ token: String, _ pollID: Int) -> String { "\(spreedV1)/poll/\(token)/\(pollID)" }

    // Core
    static let autocomplete = "\(ocs)/core/autocomplete/get"

    // Core unified search. Talk registers `talk-message` here rather than exposing a
    // search endpoint of its own, which is why message search is a core path.
    static let searchProviders = "\(ocs)/search/providers"
    static func searchProvider(_ id: String) -> String { "\(ocs)/search/providers/\(id)/search" }

    /// Nextcloud's thumbnail service. Built with query items at the call site so the
    /// parameters are escaped properly.
    static let preview = "/index.php/core/preview"

    // Files sharing (not Talk — the Files app's share API, used for attachments)
    static let shares = "\(ocs)/apps/files_sharing/api/v1/shares"

    /// WebDAV path for a file in the user's own storage.
    static func webDAV(userID: String, path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let encodedUser = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        let encodedPath = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "/remote.php/dav/files/\(encodedUser)/\(encodedPath)"
    }

    // Attendees
    static func attendees(_ token: String) -> String { "\(spreedV4)/room/\(token)/attendees" }

    // Shared items
    static func sharedItems(_ token: String) -> String { "\(spreedV1)/chat/\(token)/share" }
    static func sharedItemsOverview(_ token: String) -> String { "\(spreedV1)/chat/\(token)/share/overview" }

    // Avatars (not OCS)
    static func userAvatar(_ userID: String, size: Int, dark: Bool = false) -> String {
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        return "/index.php/avatar/\(encoded)/\(size)" + (dark ? "/dark" : "")
    }
}
