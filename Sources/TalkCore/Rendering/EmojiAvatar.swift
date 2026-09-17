import Foundation

/// A conversation picture Talk made from an emoji: a square of one colour with the emoji as
/// SVG text on it (`AvatarService::$svgTemplate`).
///
/// Drawn from its parts rather than as the SVG: the system's SVG renderer ignores the
/// `text-anchor: middle` that centres the emoji, so it lands off to one side — so the colour
/// and the emoji are read out and drawn natively instead.
struct EmojiAvatar: Sendable, Equatable {
    /// `RRGGBB`, without the `#`.
    var fillHex: String
    var emoji: String

    static func parse(_ data: Data) -> EmojiAvatar? {
        guard data.count < 16_000, let svg = String(data: data, encoding: .utf8),
              svg.contains("<svg"), svg.contains("<text")
        else { return nil }

        guard let fill = firstMatch(##"<rect[^>]*fill="#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})""##, in: svg),
              let text = firstMatch(#"<text[^>]*>([^<]+)</text>"#, in: svg)
        else { return nil }

        let emoji = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty, emoji.count <= 2 else { return nil }
        let hex = fill.count == 3 ? fill.map { "\($0)\($0)" }.joined() : fill
        return EmojiAvatar(fillHex: hex.lowercased(), emoji: emoji)
    }

    /// The fill as red, green and blue from 0 to 1.
    var rgb: (red: Double, green: Double, blue: Double) {
        let value = UInt32(fillHex, radix: 16) ?? 0
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);|&#([0-9]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result) else { continue }
                let hex = Range(match.range(at: 1), in: result).map { UInt32(result[$0], radix: 16) } ?? nil
                let dec = Range(match.range(at: 2), in: result).map { UInt32(result[$0]) } ?? nil
                if let scalar = (hex ?? dec).flatMap(Unicode.Scalar.init) {
                    result.replaceSubrange(whole, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
