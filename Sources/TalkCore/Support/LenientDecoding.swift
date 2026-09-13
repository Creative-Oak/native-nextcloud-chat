import Foundation

/// Nextcloud is inconsistent about JSON scalars: the same config value can arrive as
/// `true`, `"1"`, or `1` depending on server version and how it was persisted. These
/// helpers decode the intent rather than the literal type, so a server quirk never turns
/// into a hard decoding failure that blanks the whole account.
enum Lenient {
    static func bool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

/// A dictionary that is sometimes sent as an empty array.
///
/// Talk does this for `messageParameters`, `reactions`, `reactionsSelf` and `lastMessage`
/// — PHP's `[]` serializes the same way whether it meant "empty list" or "empty map".
@propertyWrapper
struct EmptyArrayTolerantDictionary<Value: Codable & Sendable>: Codable, Sendable {
    var wrappedValue: [String: Value]

    init(wrappedValue: [String: Value]) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        if let dictionary = try? [String: Value](from: decoder) {
            wrappedValue = dictionary
        } else if let array = try? [Value](from: decoder), array.isEmpty {
            wrappedValue = [:]
        } else if let array = try? [String](from: decoder), array.isEmpty {
            wrappedValue = [:]
        } else {
            wrappedValue = [:]
        }
    }

    func encode(to encoder: any Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    func decode<Value>(
        _ type: EmptyArrayTolerantDictionary<Value>.Type,
        forKey key: Key
    ) throws -> EmptyArrayTolerantDictionary<Value> {
        try decodeIfPresent(type, forKey: key) ?? EmptyArrayTolerantDictionary(wrappedValue: [:])
    }
}
