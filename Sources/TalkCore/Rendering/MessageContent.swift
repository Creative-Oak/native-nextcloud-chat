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

    /// The name as it is shown, with an `@` in front of it. A display name is server
    /// text; see ``Swift/String/withoutInvisibleMarks`` for what is taken out of it.
    var displayLabel: String { "@" + label.withoutInvisibleMarks }
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
            // A sidebar row and a notification banner are one line of borrowed text; a
            // message does not get to reorder the chrome around it.
            .withoutInvisibleMarks
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

    /// Every web link in the message, in the order they appear, for the menu that offers
    /// to copy one. A label can say anything; this is the other half of being able to
    /// find out what it actually meant.
    var webLinks: [URL] {
        var found: [URL] = []
        for block in blocks {
            block.collectWebLinks(into: &found)
            if found.count >= MessageContentParser.maximumLinksListed { break }
        }
        return Array(found.prefix(MessageContentParser.maximumLinksListed))
    }
}

private extension MessageBlock {
    func collectWebLinks(into found: inout [URL]) {
        switch self {
        case .paragraph(let nodes):
            nodes.collectWebLinks(into: &found)
        case .quote(let blocks):
            for block in blocks { block.collectWebLinks(into: &found) }
        case .list(_, let items):
            for item in items { item.collectWebLinks(into: &found) }
        case .code, .attachment:
            // Code is shown as written, and an attachment's own link is the server's,
            // not something a sender wrote into the sentence.
            break
        }
    }

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
    func collectWebLinks(into found: inout [URL]) {
        for node in self {
            switch node {
            case .link(let url, _):
                if url.isWebLink { found.append(url) }
            case .markdown(let source):
                // Markdown text goes to the renderer whole, links and all, so the parser
                // never split its URLs out. Found here the same way instead.
                found.append(contentsOf: MessageContentParser.webLinks(in: source))
            default:
                continue
            }
        }
    }

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
    ///
    /// This is the only answer to that question in the app. Every place that opens a URL
    /// somebody else put in a message, or turns one into something clickable, asks here
    /// and nowhere else: a second list kept somewhere near the thing it guards drifts from
    /// this one, and the gap between them is exactly where `smb://`, `file://` and
    /// `shortcuts://` would walk through.
    ///
    /// Credentials in the authority are refused with them. `https://cloud.example.com@evil.tld`
    /// goes to `evil.tld`, and a reader being shown where a link goes should not have to
    /// know that.
    var isWebLink: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = host(), !host.isEmpty else { return false }
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return false }
        return components.user == nil && components.password == nil
    }

    /// A link worth fetching a preview for.
    ///
    /// The fetch happens on the reader's own machine, the moment the message scrolls into
    /// view, and the address was chosen by whoever sent it. So anything that only resolves
    /// inside the reader's network gets no card: the card would be a report on a network
    /// the sender cannot otherwise reach, delivered to the sender.
    ///
    /// This cannot be complete — a name in public DNS is free to point at `10.0.0.5`, and
    /// nothing short of resolving it first would notice. It removes the easy half: the
    /// address typed straight into the message.
    var isPreviewableWebLink: Bool {
        guard isWebLink, let host = host()?.lowercased() else { return false }
        if ServerAddress.isLocalHost(host) { return false }
        // A raw address in any of the spellings that resolve to one — `10.0.0.5`, `::1`,
        // `0x7f.1`, `2130706433`. A page worth a card has a name.
        if Self.isNumericHost(host) { return false }
        // A single label resolves only against the reader's own search domain.
        if !host.contains(".") { return false }
        return true
    }

    private static func isNumericHost(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            if label.hasPrefix("0x") {
                return label.count > 2 && label.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
            }
            return !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

extension String {
    /// The same text, without the characters that can lie about it: the bidirectional
    /// overrides and isolates, which reorder the words around them, and the zero-width
    /// characters, which make two different names look like the same one.
    ///
    /// A display name and a link label both come off the wire and are both read as a
    /// claim about something else — who is being addressed, where a click goes. Neither
    /// gets to reorder the sentence it sits in, and neither gets to hide half of itself.
    ///
    /// The zero-width joiner survives between two pictographs, because that is how a
    /// family or a profession emoji is spelled and a cheerful name is not an attack.
    var withoutInvisibleMarks: String {
        guard unicodeScalars.contains(where: Self.isInvisibleMark) else { return self }

        let scalars = Array(unicodeScalars)
        var kept = String.UnicodeScalarView()
        kept.reserveCapacity(scalars.count)
        for (offset, scalar) in scalars.enumerated() {
            guard Self.isInvisibleMark(scalar) else {
                kept.append(scalar)
                continue
            }
            if scalar.value == 0x200D, Self.joinsPictographs(scalars, at: offset) {
                kept.append(scalar)
            }
        }
        return String(kept)
    }

    private static func isInvisibleMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // LRE, RLE, PDF, LRO, RLO — the ones that reverse whatever follows them.
        case 0x202A...0x202E: true
        // LRI, RLI, FSI, PDI — the isolates, which do the same thing more politely.
        case 0x2066...0x2069: true
        // Zero-width space, non-joiner and joiner, and the left/right marks beside them.
        case 0x200B...0x200F: true
        // The byte-order mark, which is a zero-width no-break space anywhere but the front.
        case 0xFEFF: true
        default: false
        }
    }

    private static func joinsPictographs(_ scalars: [Unicode.Scalar], at offset: Int) -> Bool {
        guard offset > 0, offset + 1 < scalars.count else { return false }
        return scalars[offset - 1].properties.isEmoji && scalars[offset + 1].properties.isEmoji
    }
}
