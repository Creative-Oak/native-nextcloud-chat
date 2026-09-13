import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Generates the `referenceId` Talk uses to match a client's optimistic message with the
/// server's copy (capability `chat-reference-id`).
///
/// The documented shape is a SHA-256-style string. It carries no information — it exists
/// only to be unique and stable for one send — so it is derived from a fresh UUID and
/// never from the message content, which would leak content into a field other
/// participants can see.
enum ReferenceID {
    static func generate() -> String {
        let seed = Data(UUID().uuidString.utf8)
        #if canImport(CryptoKit)
        return SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
        #else
        // No CryptoKit (Linux tests): two UUIDs give the same 64 hex characters of entropy.
        let hex = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return String(hex.prefix(64))
        #endif
    }

    /// The local identity an optimistic message keeps for its whole life.
    static func localID(for reference: String) -> String { "pending-\(reference)" }
}
