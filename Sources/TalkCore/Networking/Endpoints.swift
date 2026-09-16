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
    static func room(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))" }
    static let noteToSelf = "\(spreedV4)/room/note-to-self"
    static func favorite(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/favorite" }
    static func archive(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/archive" }
    static func important(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/important" }
    static func sensitive(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/sensitive" }
    static func notify(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/notify" }
    static func participants(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/participants" }
    static func activeParticipants(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/participants/active" }
    static func sessionState(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/participants/state" }
    static func conversationAvatar(_ token: String, dark: Bool = false) -> String {
        "\(spreedV1)/room/\(segment(token))/avatar" + (dark ? "/dark" : "")
    }

    // Chat (v1)
    static func chat(_ token: String) -> String { "\(spreedV1)/chat/\(segment(token))" }
    static func chatMessage(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/chat/\(segment(token))/\(messageID)" }
    static func chatReadMarker(_ token: String) -> String { "\(spreedV1)/chat/\(segment(token))/read" }
    static func chatContext(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/chat/\(segment(token))/\(messageID)/context" }
    static func mentions(_ token: String) -> String { "\(spreedV1)/chat/\(segment(token))/mentions" }
    static func reaction(_ token: String, _ messageID: Int) -> String { "\(spreedV1)/reaction/\(segment(token))/\(messageID)" }

    static func poll(_ token: String) -> String { "\(spreedV1)/poll/\(segment(token))" }
    static func poll(_ token: String, _ pollID: Int) -> String { "\(spreedV1)/poll/\(segment(token))/\(pollID)" }

    // Core
    static let autocomplete = "\(ocs)/core/autocomplete/get"

    // Core unified search. Talk registers `talk-message` here rather than exposing a
    // search endpoint of its own, which is why message search is a core path.
    static let searchProviders = "\(ocs)/search/providers"
    static func searchProvider(_ id: String) -> String { "\(ocs)/search/providers/\(segment(id))/search" }

    /// Nextcloud's thumbnail service. Built with query items at the call site so the
    /// parameters are escaped properly.
    static let preview = "/index.php/core/preview"

    // Files sharing (not Talk — the Files app's share API, used for attachments)
    static let shares = "\(ocs)/apps/files_sharing/api/v1/shares"

    /// A path inside the user's own storage, every segment of it made safe.
    ///
    /// The one spelling of a file this app uses. An attachment is written over WebDAV and
    /// then shared by name through a different API, and the two have to name the same
    /// file: **the path used to write and the path used to share are the same string**.
    /// That holds because ``AttachmentService`` asks here once and keeps the answer, and
    /// because a second pass changes nothing — a path that has been through `filePath` is
    /// already a sequence of single, safe segments, so ``webDAV(userID:path:)`` can be
    /// handed one without mangling it a second time.
    static func filePath(_ path: String) -> String {
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment(String($0)) }
            .joined(separator: "/")
        return "/" + parts
    }

    /// WebDAV path for a file in the user's own storage.
    ///
    /// The file name goes in decoded, like every other path here. It used to be
    /// percent-encoded first and then encoded again by `URLComponents`, which is why a
    /// space became `%2520` and `café.pdf` became `caf%25C3%25A9.pdf`.
    static func webDAV(userID: String, path: String) -> String {
        "/remote.php/dav/files/\(segment(userID))\(filePath(path))"
    }

    // Attendees
    static func attendees(_ token: String) -> String { "\(spreedV4)/room/\(segment(token))/attendees" }

    // Shared items
    static func sharedItems(_ token: String) -> String { "\(spreedV1)/chat/\(segment(token))/share" }
    static func sharedItemsOverview(_ token: String) -> String { "\(spreedV1)/chat/\(segment(token))/share/overview" }

    // The signed-in user's profile and status
    static func cloudUser(_ userID: String) -> String { "\(ocs)/cloud/users/\(segment(userID))" }
    static let userStatusAPI = "\(ocs)/apps/user_status/api/v1"
    static let userStatus = "\(userStatusAPI)/user_status"
    static let userStatusType = "\(userStatusAPI)/user_status/status"
    static let userStatusMessage = "\(userStatusAPI)/user_status/message"
    static let userStatusCustomMessage = "\(userStatusAPI)/user_status/message/custom"
    static let userStatusPredefinedMessage = "\(userStatusAPI)/user_status/message/predefined"
    /// With the trailing slash the route is declared with.
    static let predefinedStatuses = "\(userStatusAPI)/predefined_statuses/"
    /// Setting or removing the signed-in user's own picture. A front-page route, not OCS.
    static let ownAvatar = "/index.php/avatar/"

    // Avatars (not OCS)
    static func userAvatar(_ userID: String, size: Int, dark: Bool = false) -> String {
        "/index.php/avatar/\(segment(userID))/\(size)" + (dark ? "/dark" : "")
    }

    // MARK: - Path safety

    /// One path segment, still decoded.
    ///
    /// ``ServerAddress/url(path:query:)`` percent-encodes on the way out, so a space, an
    /// accent, a `%`, a `&`, a `?` or a `#` in a token or a file name is already harmless
    /// by the time it reaches the wire. What encoding cannot undo is *structure*: a `/`
    /// would add a segment and re-point the call, and a `.` or `..` segment would walk up
    /// the path — so a token of `../../index.php` must not be allowed to turn an
    /// authenticated POST into a POST somewhere else. Those characters are flattened to
    /// `_`, which yields a conversation that does not exist rather than a different
    /// endpoint.
    ///
    /// Only the structural ones. `?` and `#` used to be flattened here as well, on the
    /// grounds that not having to trust `URLComponents` cost nothing. It cost `Invoice
    /// #42.pdf`: the name was flattened on the way into the URL and not on the way back
    /// out, so the file went up as `Invoice _42.pdf` and the share that followed asked the
    /// server for a file it had never written. Neither character can start a query or a
    /// fragment from inside a path once escaped — `URLComponents` escapes both, and
    /// ``EndpointPathTests`` pins that rather than leaving it to be discovered.
    static func segment(_ raw: String) -> String {
        let flattened = String(raw.map { character -> Character in
            if character == "/" || character == "\\" { return "_" }
            if let ascii = character.asciiValue, ascii < 0x20 || ascii == 0x7F { return "_" }
            return character
        })
        // A bare `.` or `..` is the whole traversal primitive; anything else containing a
        // dot (`report.pdf`, `v2.php`) is an ordinary name.
        if flattened.isEmpty || flattened == "." || flattened == ".." { return "_" }
        return flattened
    }

    /// The shape of a path, with the parts that identify a person or a conversation removed.
    ///
    /// A conversation token is a capability — anyone holding one can open the conversation —
    /// and user ids and file names are personal data, so none of them belong in a log that
    /// survives in a sysdiagnose. What is useful there is which call was made, so every
    /// segment that is not one of this file's own fixed route words is elided. A new route
    /// whose word is missing from the list logs as `…`, which is the safe way to be wrong.
    static func redacted(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { part in part.isEmpty || routeWords.contains(String(part)) ? String(part) : "…" }
            .joined(separator: "/")
    }

    private static let routeWords: Set<String> = [
        "ocs", "v2.php", "index.php", "remote.php", "apps", "spreed", "api", "v1", "v2", "v4",
        "cloud", "capabilities", "user", "core", "apppassword", "login", "autocomplete", "get",
        "room", "note-to-self", "favorite", "archive", "important", "sensitive", "notify", "participants", "active", "state",
        "avatar", "dark", "chat", "read", "context", "mentions", "reaction", "poll",
        "search", "providers", "preview", "files_sharing", "shares", "dav", "files",
        "attendees", "share", "overview", "call",
        "users", "user_status", "status", "message", "custom", "predefined", "predefined_statuses"
    ]
}
