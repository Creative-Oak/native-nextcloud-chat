import Foundation

/// A mention, resolved for display.
struct Mention: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case user
        case group
        /// `@all` — Talk sends this as a `call` rich object.
        case everyone
        case guest
        case federatedUser
        case circle
        case email
    }

    var kind: Kind
    var id: String
    var label: String
    /// Drives the highlighted "this one is about you" treatment.
    var isCurrentUser: Bool
    var server: String?

    var displayLabel: String { "@" + label }
}

/// An inline run inside a paragraph.
///
/// `markdown` carries *source* text, not rendered HTML — the UI turns it into an
/// `AttributedString` with Apple's inline-only Markdown parser. No HTML is ever produced,
/// parsed or rendered anywhere in this pipeline.
enum InlineNode: Sendable, Hashable {
    case text(String)
    case markdown(String)
    case mention(Mention)
    case link(url: URL, label: String)
    case code(String)
    /// A rich object we have no richer rendering for; shown as its name.
    case object(RichObject)

    /// Plain-text projection, for notification previews, sidebar previews, and accessibility.
    var plainText: String {
        switch self {
        case .text(let value), .markdown(let value), .code(let value): value
        case .mention(let mention): mention.displayLabel
        case .link(_, let label): label
        case .object(let object): object.name
        }
    }
}

/// A block-level element.
enum MessageBlock: Sendable, Hashable {
    case paragraph([InlineNode])
    case code(String, language: String?)
    case quote([MessageBlock])
    case list(isOrdered: Bool, items: [[InlineNode]])
    /// A file, image, poll or location, rendered as a card rather than as text.
    case attachment(RichObject)

    var plainText: String {
        switch self {
        case .paragraph(let nodes): nodes.map(\.plainText).joined()
        case .code(let text, _): text
        case .quote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .list(_, let items): items.map { $0.map(\.plainText).joined() }.joined(separator: "\n")
        case .attachment(let object): object.name
        }
    }
}

/// The parsed form of a message, ready to render.
struct MessageContent: Sendable, Hashable {
    var blocks: [MessageBlock]
    /// True when any mention in the message refers to the current user — drives both the
    /// highlight treatment and whether a notification counts as a mention.
    var mentionsCurrentUser: Bool

    static let empty = MessageContent(blocks: [], mentionsCurrentUser: false)

    /// The attachment that draws its own container, and whatever else the message said.
    ///
    /// A picture and a poll are shapes in their own right: Messages gives neither a bubble,
    /// and puts a caption in a small bubble of its own underneath. Anything without a shape
    /// — a file row, a location — stays in the bubble where it belongs.
    var standalone: (object: RichObject, caption: [MessageBlock])? {
        var shape: RichObject?
        var caption: [MessageBlock] = []

        for block in blocks {
            guard case .attachment(let object) = block else {
                caption.append(block)
                continue
            }
            // Two of them have no obvious arrangement, so the bubble keeps them together.
            guard shape == nil, object.drawsItsOwnShape else { return nil }
            shape = object
        }

        guard let shape else { return nil }
        return (shape, caption)
    }

    /// One-line projection for sidebar previews and notification bodies.
    var preview: String {
        blocks
            .map(\.plainText)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { blocks.isEmpty }

    /// True when the whole message is a single attachment card with no words around it.
    var isAttachmentOnly: Bool {
        blocks.count == 1 && { if case .attachment = blocks[0] { return true } else { return false } }()
    }

    /// The first web link in the message, for a preview card. Only http(s), and only
    /// links the parser found in the text — not a shared file's own link.
    var firstWebLink: URL? {
        for block in blocks {
            if let url = block.firstWebLink { return url }
        }
        return nil
    }
}

private extension MessageBlock {
    var firstWebLink: URL? {
        switch self {
        case .paragraph(let nodes):
            return nodes.firstWebLink
        case .quote(let blocks):
            return blocks.lazy.compactMap(\.firstWebLink).first
        case .list(_, let items):
            return items.lazy.compactMap(\.firstWebLink).first
        case .code, .attachment:
            return nil
        }
    }
}

private extension [InlineNode] {
    var firstWebLink: URL? {
        for node in self {
            switch node {
            case .link(let url, _):
                if url.isWebLink { return url }
            case .markdown(let source):
                // Markdown text goes to the renderer whole, links and all, so the
                // parser never split its URLs out. Found here the same way instead.
                if let url = MessageContentParser.firstWebLink(in: source) { return url }
            default:
                continue
            }
        }
        return nil
    }
}

extension URL {
    /// Something a browser can open — and a preview can be fetched for.
    var isWebLink: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && host() != nil
    }
}
