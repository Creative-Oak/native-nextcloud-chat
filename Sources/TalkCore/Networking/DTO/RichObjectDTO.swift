import Foundation

/// A coding key whose name isn't known until decoding time.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

/// One `messageParameters` entry.
///
/// Rich objects are documented as string maps, but real servers mix in numbers and bools
/// (`size`, `width`, `hide-download`). Everything that isn't `type`/`id`/`name` is
/// normalized to a string so a type surprise can never fail the decode of an entire
/// conversation's history.
struct RichObjectDTO: Decodable, Sendable {
    let object: RichObject

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        var type = ""
        var id = ""
        var name = ""
        var attributes: [String: String] = [:]

        for key in container.allKeys {
            guard let value = Self.scalar(container, key) else { continue }
            switch key.stringValue {
            case "type": type = value
            case "id": id = value
            case "name": name = value
            default: attributes[key.stringValue] = value
            }
        }

        object = RichObject(type: RichObject.Kind(rawValue: type), id: id, name: name, attributes: attributes)
    }

    private static func scalar(_ container: KeyedDecodingContainer<DynamicCodingKey>, _ key: DynamicCodingKey) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

extension Dictionary where Key == String, Value == RichObjectDTO {
    var objects: [String: RichObject] { mapValues(\.object) }
}
