import Foundation

#if canImport(CryptoKit)
import CryptoKit

/// How cached content is sealed before it reaches SQLite.
///
/// AES-GCM, with the kind of row as associated data so a sealed message can't be passed off
/// as a draft or an account. A sealed blob starts with a version byte. A pre-encryption
/// payload is JSON and starts with `{`, which is how one is recognised.
enum CacheCipher {
    enum Kind: String {
        case account, conversation, message, draft
    }

    private static let version: UInt8 = 1
    /// Draft text lives in a `String` column, so sealed text is base64 behind this marker.
    /// A control character, so no draft a person typed starts with it.
    private static let textMarker = "\u{1}1:"

    static func seal(_ plaintext: Data, kind: Kind, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(kind.rawValue.utf8))
        // `combined` is nil only for a nonce of non-standard length, and this one is the default.
        return Data([version]) + box.combined!
    }

    static func open(_ sealed: Data, kind: Kind, key: SymmetricKey) throws -> Data {
        guard isSealed(sealed) else { throw CryptoKitError.authenticationFailure }
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
        return try AES.GCM.open(box, using: key, authenticating: Data(kind.rawValue.utf8))
    }

    static func isSealed(_ data: Data) -> Bool {
        data.first == version
    }

    static func seal(text: String, key: SymmetricKey) throws -> String {
        textMarker + (try seal(Data(text.utf8), kind: .draft, key: key)).base64EncodedString()
    }

    static func open(text: String, key: SymmetricKey) throws -> String {
        guard isSealed(text: text), let data = Data(base64Encoded: String(text.dropFirst(textMarker.count))) else {
            throw CryptoKitError.authenticationFailure
        }
        return String(decoding: try open(data, kind: .draft, key: key), as: UTF8.self)
    }

    static func isSealed(text: String) -> Bool {
        text.hasPrefix(textMarker)
    }
}
#endif
