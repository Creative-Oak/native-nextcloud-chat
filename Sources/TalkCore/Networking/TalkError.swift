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
            "“\(input)” doesn’t look like a Nextcloud address."
        case .insecureServer(let host):
            "\(host) doesn’t use HTTPS. kvidr requires a secure connection."
        case .missingCapability(let name):
            "This server’s Talk version doesn’t support \(name)."
        case .notAuthenticated:
            "You’re not signed in."
        case .offline:
            "No internet connection."
        case .timedOut:
            "The server took too long to respond."
        case .cancelled:
            "Cancelled."
        case .transport(_, let description):
            description
        case .untrustedCertificate(let host):
            "The certificate for \(host) couldn’t be verified."
        case .responseTooLarge:
            "The server sent far more data than that should need."
        case .redirectRefused(let host):
            "\(host) tried to send this request somewhere else. kvidr only talks to your own server."
        case .unauthorized:
            "Your session has expired. Sign in again to continue."
        case .forbidden(let message):
            Self.quoting(message) ?? "You don’t have permission to do that."
        case .notFound:
            "That conversation or message no longer exists."
        case .conflict(let message):
            Self.quoting(message) ?? "That conflicted with a change on the server."
        case .sessionExpired:
            "Reconnecting…"
        case .payloadTooLarge:
            "That message is too long for this server."
        case .federationUnsupported:
            "This action isn’t available in federated conversations."
        case .federationUnreachable:
            "The remote server isn’t reachable right now."
        case .clientTooOld(let minimum):
            if let minimum {
                "This server requires a newer client (\(minimum) or later)."
            } else {
                "This server requires a newer client."
            }
        case .rateLimited:
            "Too many requests — slowing down."
        case .maintenanceMode:
            "The server is in maintenance mode."
        case .serverError(let status, _):
            "The server reported an error (\(status))."
        case .ocs(_, let message):
            Self.quoting(message) ?? "The server rejected that request."
        case .decoding, .unexpectedResponse:
            "The server sent something unexpected."
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
        return "The server says: “\(message)”"
    }

    /// One line, no control characters, at most ``serverTextLimit`` characters.
    ///
    /// Applied wherever server text enters an error payload, so the bound travels with the
    /// value rather than depending on every call site remembering it.
    static func sanitizedServerText(_ message: String?) -> String? {
        guard let message else { return nil }
        var cleaned = String(message.unicodeScalars.map { scalar in
            // C0/C1 controls, which is where line breaks, tabs and terminal escapes live.
            (scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)) ? " " : Character(scalar)
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
