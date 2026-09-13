import Foundation

/// A Nextcloud app password and the login name it belongs to.
///
/// The app password is a credential for the *device*, obtained through Login Flow v2 and
/// stored only in the Keychain. `description` is deliberately redacted so that an
/// accidental interpolation into a log line cannot leak it.
struct Credentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let loginName: String
    let appPassword: String

    var authorizationHeaderValue: String {
        "Basic " + Data("\(loginName):\(appPassword)".utf8).base64EncodedString()
    }

    var description: String { "Credentials(loginName: \(loginName), appPassword: <redacted>)" }
    var debugDescription: String { description }
}
