import Foundation

/// Every failure this client can produce, as a value.
///
/// Deliberately not `String`-based: call sites switch on these, the UI maps them to
/// quiet inline states, and the sync engines ask them whether retrying is worthwhile.
enum TalkError: Error, Sendable, Equatable {
    // Configuration
    case invalidServerURL(String)
    case insecureServer(host: String)
    case missingCapability(String)
    case notAuthenticated

    // Transport
    case offline
    case timedOut
    case cancelled
    case transport(code: Int, description: String)
    case untrustedCertificate(host: String)
    /// The response body went past the ceiling the request asked for, and was abandoned.
    case responseTooLarge
    /// A redirect wanted to leave the origin the request was aimed at, and was refused.
    case redirectRefused(host: String)

    /// The Keychain wouldn't take or give up a secret the app needs.
    case keychainUnavailable

    // Attachments
    /// Not a regular file on this Mac — a link, a folder, a pipe, a device, or nothing at all.
    case fileNotAttachable
    /// The file was there when it was attached and isn't now — moved, deleted, or on a
    /// share that has since been unmounted.
    case fileMissing
    /// Bigger than the place it's going will take.
    case fileTooLarge
    /// Chosen as a picture, and not one.
    case fileNotAPicture
    /// The disk the file is on stopped answering: a network share whose server has gone.
    case fileNotAnswering

    // HTTP / OCS
    case unauthorized
    case forbidden(message: String?)
    case notFound
    case conflict(message: String?)
    case sessionExpired          // 412 — the Talk room session is gone; re-join
    case payloadTooLarge
    case federationUnsupported   // 406
    case federationUnreachable   // 422
    case clientTooOld(minimumVersion: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case maintenanceMode
    case serverError(status: Int, message: String?)
    case ocs(status: Int, message: String?)

    // Payload
    case decoding(context: String)
    case unexpectedResponse(String)

    /// Worth trying again on a timer.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .transport, .rateLimited, .maintenanceMode, .serverError:
            true
        case .sessionExpired:
            true   // retryable, but only after re-joining the room
        default:
            false
        }
    }

    /// The account's app password is no longer valid — stop everything and ask the user.
    var requiresReauthentication: Bool {
        self == .unauthorized
    }

    /// How long a backoff should wait before the next attempt, when the server told us.
    var suggestedRetryDelay: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter): retryAfter
        case .maintenanceMode: 60
        default: nil
        }
    }

    /// Short, calm, user-facing. No stack traces, no HTTP jargon where it can be avoided.
    var userMessage: String {
        switch self {
        case .invalidServerURL(let input):
            String(localized: "“\(input)” doesn’t look like a Nextcloud address.", comment: "%@ is what the user typed as the server address")
        case .insecureServer(let host):
            String(localized: "\(host) doesn’t use HTTPS. kvidr requires a secure connection.", comment: "%@ is a server’s host name")
        case .missingCapability(let name):
            String(localized: "This server’s Talk version doesn’t support \(name).", comment: "%@ is a feature, e.g. “Nextcloud Talk” or “a supported Talk version (chat-v2)”")
        case .notAuthenticated:
            String(localized: "You’re not signed in.")
        case .offline:
            String(localized: "No internet connection.")
        case .timedOut:
            String(localized: "The server took too long to respond.")
        case .cancelled:
            String(localized: "Cancelled.", comment: "Error text: the operation was cancelled")
        case .transport(_, let description):
            description
        case .untrustedCertificate(let host):
            String(localized: "The certificate for \(host) couldn’t be verified.", comment: "%@ is a server’s host name")
        case .responseTooLarge:
            String(localized: "The server sent far more data than that should need.")
        case .redirectRefused(let host):
            String(localized: "\(host) tried to send this request somewhere else. kvidr only talks to your own server.", comment: "%@ is a server’s host name")
        case .keychainUnavailable:
            String(localized: "kvidr couldn’t use your Keychain, so your sign-in couldn’t be saved.")
        case .fileNotAttachable:
            String(localized: "Only files on this Mac can be attached.")
        case .fileTooLarge:
            String(localized: "That file is too big.")
        case .fileNotAPicture:
            String(localized: "That file isn’t a picture kvidr can read.")
        case .fileMissing:
            String(localized: "That file isn’t there anymore.")
        case .fileNotAnswering:
            String(localized: "The disk that file is on isn’t answering.")
        case .unauthorized:
            String(localized: "Your session has expired. Sign in again to continue.")
        case .forbidden(let message):
            Self.quoting(message) ?? String(localized: "You don’t have permission to do that.")
        case .notFound:
            String(localized: "That conversation or message no longer exists.")
        case .conflict(let message):
            Self.quoting(message) ?? String(localized: "That conflicted with a change on the server.")
        case .sessionExpired:
            String(localized: "Reconnecting…")
        case .payloadTooLarge:
            String(localized: "That message is too long for this server.")
        case .federationUnsupported:
            String(localized: "This action isn’t available in federated conversations.")
        case .federationUnreachable:
            String(localized: "The remote server isn’t reachable right now.")
        case .clientTooOld(let minimum):
            if let minimum {
                String(localized: "This server requires a newer client (\(minimum) or later).", comment: "%@ is a version number")
            } else {
                String(localized: "This server requires a newer client.")
            }
        case .rateLimited:
            String(localized: "Too many requests — slowing down.")
        case .maintenanceMode:
            String(localized: "The server is in maintenance mode.")
        case .serverError(let status, _):
            String(localized: "The server reported an error (\(status)).", comment: "%lld is an HTTP status code")
        case .ocs(_, let message):
            Self.quoting(message) ?? String(localized: "The server rejected that request.")
        case .decoding, .unexpectedResponse:
            String(localized: "The server sent something unexpected.")
        }
    }

    /// Frames a line the *server* wrote so it cannot be mistaken for the app's own voice.
    ///
    /// `ocs.meta.message` is free text chosen by whoever runs (or has taken over) the
    /// server, and it used to be printed verbatim in first-party chrome — which is an
    /// invitation to write "Your session expired, re-enter your password at …" in kvidr's
    /// own words. Attributed and bounded, it is still useful and no longer impersonation.
    /// The length cap is a second job: a multi-kilobyte line is a layout weapon.
    static func quoting(_ message: String?) -> String? {
        guard let message = sanitizedServerText(message) else { return nil }
        return String(localized: "The server says: “\(message)”", comment: "%@ is a message the server wrote, shown verbatim")
    }

    /// One line, no control characters, at most ``serverTextLimit`` characters.
    ///
    /// Applied wherever server text enters an error payload, so the bound travels with the
    /// value rather than depending on every call site remembering it.
    static func sanitizedServerText(_ message: String?) -> String? {
        guard let message else { return nil }
        var cleaned = String(message.unicodeScalars.map { scalar -> Character in
            // C0/C1 controls, which is where line breaks, tabs and terminal escapes live.
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return " " }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > serverTextLimit {
            cleaned = String(cleaned.prefix(serverTextLimit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }

    static let serverTextLimit = 200

    /// Maps a transport-level HTTP status (plus any OCS message) onto a typed error.
    static func from(status: Int, ocsMessage: String? = nil, headers: HTTPHeaders = .init()) -> TalkError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden(message: ocsMessage)
        case 404: .notFound
        case 406: .federationUnsupported
        case 409: .conflict(message: ocsMessage)
        case 412: .sessionExpired
        case 413: .payloadTooLarge
        case 422: .federationUnreachable
        case 426: .clientTooOld(minimumVersion: ocsMessage)
        case 429: .rateLimited(retryAfter: headers.retryAfter)
        case 503: .maintenanceMode
        case 500...599: .serverError(status: status, message: ocsMessage)
        default: .ocs(status: status, message: ocsMessage)
        }
    }
}
