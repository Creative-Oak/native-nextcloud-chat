import Foundation

/// What forwarding a message into another conversation sends — worked out the way Talk's web
/// app does it: words are posted again, a file is shared again rather than copied, and
/// anything that only means something where it was (a poll, a system line) isn't offered.
enum ForwardPlan: Sendable, Equatable {
    /// Post these words.
    case text(String)
    /// Share this file, from the user's own storage, with a caption.
    case file(path: String, caption: String, isVoiceMessage: Bool)

    static func plan(for message: Message) -> ForwardPlan? {
        guard !message.isSystem, !message.isDeleted, message.kind != .commentDeleted,
              !message.deliveryState.isPending, message.messageID > 0
        else { return nil }

        let segments = MessageContentParser.splitPlaceholders(message.text)
        let objects = segments.compactMap { segment -> RichObject? in
            if case .placeholder(let key, _) = segment { return message.parameters[key] } else { return nil }
        }

        // A captioned share keeps its file in the parameters without naming it in the text.
        let unreferenced = message.parameters
            .filter { key, _ in !MessageContentParser.referencedKeys(in: message.text).contains(key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
        if let file = (objects + unreferenced).first(where: { $0.type == .file }) {
            guard let path = file.path, !path.isEmpty else { return nil }
            let caption = text(of: segments, parameters: message.parameters, dropping: file)
            return .file(path: path, caption: caption, isVoiceMessage: message.isVoiceMessage)
        }
        // A poll, a location, a Deck card: things that live in their own conversation.
        if (objects + unreferenced).contains(where: { MessageContentParser.isAttachment($0) }) { return nil }

        let words = text(of: segments, parameters: message.parameters, dropping: nil)
        return words.isEmpty ? nil : .text(words)
    }

    /// The message with its placeholders written out. A mention becomes "@Name" as plain text:
    /// forwarding a message shouldn't notify the people it once mentioned.
    private static func text(
        of segments: [MessageContentParser.Segment],
        parameters: [String: RichObject],
        dropping dropped: RichObject?
    ) -> String {
        segments.map { segment -> String in
            switch segment {
            case .literal(let text):
                return text
            case .placeholder(let key, let original):
                guard let object = parameters[key] else { return original }
                if let dropped, object == dropped { return "" }
                switch object.type {
                case .user, .guest, .userGroup, .call, .email, .circle:
                    return "@" + object.displayName
                default:
                    return object.displayName
                }
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
