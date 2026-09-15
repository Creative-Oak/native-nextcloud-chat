import Foundation

/// Turns a Talk message into renderable nodes.
///
/// Two rules govern everything here:
///
/// 1. **Placeholders are substituted structurally.** The raw text is scanned once; a
///    `{key}` that exists in `messageParameters` becomes a node, and the node's payload is
///    never re-scanned. A display name of `{mention-user1}` is therefore just text and
///    cannot forge a mention.
/// 2. **Markdown source is passed through, never HTML.** Blocks are split here; inline
///    emphasis is left to Apple's Markdown parser at render time.
struct MessageContentParser: Sendable {
    /// Used to decide whether a mention is *about you*.
    let currentUserID: String
    /// Talk only sets `markdown` when the server has `markdown-messages`; the caller passes
    /// the per-message flag and we honour it exactly.
    let markdownEnabled: Bool

    /// A message is a message. A server that hangs ten thousand files off one is not
    /// describing a share, and the transcript — which draws these blocks eagerly, and asks
    /// the server for a thumbnail of each — should not try to draw it.
    static let maximumTrailingAttachments = 16

    init(currentUserID: String, markdownEnabled: Bool = true) {
        self.currentUserID = currentUserID
        self.markdownEnabled = markdownEnabled
    }

    func parse(_ message: Message) -> MessageContent {
        parse(
            text: message.text,
            parameters: message.parameters,
            isMarkdown: message.isMarkdown && markdownEnabled,
            isSystem: message.isSystem
        )
    }

    func parse(
        text: String,
        parameters: [String: RichObject],
        isMarkdown: Bool,
        isSystem: Bool = false
    ) -> MessageContent {
        var mentionsCurrentUser = false

        // A message whose entire text is one attachment placeholder is a file share, a poll
        // or a location: it renders as a card, not as a sentence.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = Self.soleplaceholder(in: trimmed),
           let object = parameters[key],
           Self.isAttachment(object) {
            return MessageContent(blocks: [.attachment(object)], mentionsCurrentUser: false)
        }

        var blocks: [MessageBlock] = []
        for rawBlock in Self.splitBlocks(text, allowMarkdown: isMarkdown) {
            switch rawBlock {
            case .code(let code, let language):
                blocks.append(.code(code, language: language))
            case .quote(let lines):
                let inner = lines.map { line -> MessageBlock in
                    let (nodes, mentioned) = inlineNodes(line, parameters: parameters, isMarkdown: isMarkdown, isSystem: isSystem)
                    mentionsCurrentUser = mentionsCurrentUser || mentioned
                    return .paragraph(nodes)
                }
                blocks.append(.quote(inner))
            case .list(let isOrdered, let items):
                var parsedItems: [[InlineNode]] = []
                for item in items {
                    let (nodes, mentioned) = inlineNodes(item, parameters: parameters, isMarkdown: isMarkdown, isSystem: isSystem)
                    mentionsCurrentUser = mentionsCurrentUser || mentioned
                    parsedItems.append(nodes)
                }
                blocks.append(.list(isOrdered: isOrdered, items: parsedItems))
            case .paragraph(let paragraph):
                let (nodes, mentioned) = inlineNodes(paragraph, parameters: parameters, isMarkdown: isMarkdown, isSystem: isSystem)
                mentionsCurrentUser = mentionsCurrentUser || mentioned
                if !nodes.isEmpty { blocks.append(.paragraph(nodes)) }
            }
        }

        // Attachments referenced alongside text (a file with a caption) get their own card
        // after the words, which is how Talk itself presents a captioned share. The cap is
        // applied after the filter, so a map padded out with ten thousand parameters that
        // are not attachments cannot spend the budget on the way past.
        let referenced = Self.referencedKeys(in: text)
        let trailing = parameters
            .sorted { $0.key < $1.key }
            .filter { !referenced.contains($0.key) && Self.isAttachment($0.value) }
            .prefix(Self.maximumTrailingAttachments)
        for (_, object) in trailing {
            blocks.append(.attachment(object))
        }

        return MessageContent(blocks: blocks, mentionsCurrentUser: mentionsCurrentUser)
    }

    // MARK: - Inline parsing

    private func inlineNodes(
        _ text: String,
        parameters: [String: RichObject],
        isMarkdown: Bool,
        isSystem: Bool
    ) -> ([InlineNode], Bool) {
        var nodes: [InlineNode] = []
        var mentionsCurrentUser = false

        for segment in Self.splitPlaceholders(text) {
            switch segment {
            case .literal(let literal):
                guard !literal.isEmpty else { continue }
                nodes.append(contentsOf: Self.linkify(literal, isMarkdown: isMarkdown))
            case .placeholder(let key, let original):
                guard let object = parameters[key] else {
                    // An unresolved placeholder is shown verbatim rather than swallowed —
                    // losing text silently is worse than showing a stray brace.
                    nodes.append(.text(original))
                    continue
                }
                let (node, isMe) = self.node(for: object, isSystem: isSystem)
                mentionsCurrentUser = mentionsCurrentUser || isMe
                nodes.append(node)
            }
        }

        return (nodes, mentionsCurrentUser)
    }

    private func node(for object: RichObject, isSystem: Bool) -> (InlineNode, Bool) {
        switch object.type {
        case .user:
            // A federated user is a `user` object carrying a `server` key.
            return mentionNode(object, kind: .user, isSystem: isSystem)
        case .guest:
            return mentionNode(object, kind: .guest, isSystem: isSystem)
        case .userGroup:
            return mentionNode(object, kind: .group, isSystem: isSystem)
        case .circle:
            return mentionNode(object, kind: .circle, isSystem: isSystem)
        case .email:
            return mentionNode(object, kind: .email, isSystem: isSystem)
        case .call:
            // `{mention-call}` is @all. In a system message it is just the room's name.
            if isSystem { return (.text(object.name), false) }
            return (.mention(Mention(kind: .everyone, id: object.id, label: object.name, isCurrentUser: false)), true)
        case .highlight:
            // `link` is already only ever a web link — see ``RichObject/link``.
            if let link = object.link { return (.link(url: link, label: object.displayName), false) }
            return (.text(object.displayName), false)
        case .openGraph, .deckCard:
            if let link = object.link { return (.link(url: link, label: object.displayName), false) }
            return (.object(object), false)
        case .file, .talkAttachment, .talkPoll, .geoLocation:
            return (.object(object), false)
        case .other:
            return (.object(object), false)
        }
    }

    private func mentionNode(_ object: RichObject, kind: Mention.Kind, isSystem: Bool) -> (InlineNode, Bool) {
        // In a system message ("{actor} added {user}") names are prose, not mentions.
        if isSystem { return (.text(object.name), false) }

        let isFederated = object.server != nil
        let isMe = kind == .user && !isFederated && object.id == currentUserID
        let mention = Mention(
            kind: isFederated ? .federatedUser : kind,
            id: object.id,
            label: object.name,
            isCurrentUser: isMe,
            server: object.server
        )
        return (.mention(mention), isMe)
    }

    // MARK: - Placeholders

    enum Segment: Sendable, Equatable {
        case literal(String)
        case placeholder(key: String, original: String)
    }

    /// Single pass, left to right. Substituted content is never re-scanned.
    static func splitPlaceholders(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "{" else {
                literal.append(character)
                index = text.index(after: index)
                continue
            }

            // Look ahead for `{key}` with a plausible key.
            var cursor = text.index(after: index)
            var key = ""
            var closed = false
            while cursor < text.endIndex {
                let next = text[cursor]
                if next == "}" { closed = true; break }
                guard next.isLetter || next.isNumber || next == "-" || next == "_" else { break }
                key.append(next)
                cursor = text.index(after: cursor)
            }

            if closed, !key.isEmpty {
                if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
                segments.append(.placeholder(key: key, original: "{\(key)}"))
                index = text.index(after: cursor)
            } else {
                literal.append(character)
                index = text.index(after: index)
            }
        }

        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }

    static func referencedKeys(in text: String) -> Set<String> {
        Set(splitPlaceholders(text).compactMap {
            if case .placeholder(let key, _) = $0 { return key } else { return nil }
        })
    }

    /// The key when the message is exactly one placeholder and nothing else.
    static func soleplaceholder(in text: String) -> String? {
        let segments = splitPlaceholders(text)
        guard segments.count == 1, case .placeholder(let key, _) = segments[0] else { return nil }
        return key
    }

    static func isAttachment(_ object: RichObject) -> Bool {
        switch object.type {
        case .file, .talkAttachment, .talkPoll, .geoLocation, .deckCard: true
        default: false
        }
    }

    // MARK: - Links

    /// As many links as a menu can usefully offer. A message with more of them is a list
    /// of links, and the menu is not where you read a list.
    static let maximumLinksListed = 8

    /// The first bare `http(s)://` URL in a piece of text, Markdown or not.
    static func firstWebLink(in text: String) -> URL? {
        webLinks(in: text, limit: 1).first
    }

    /// Every bare `http(s)://` URL in a piece of text, Markdown or not, in the order they
    /// appear. Sentence punctuation and a closing Markdown bracket after one are not part
    /// of it.
    ///
    /// One loop, so the URL a preview card is fetched for and the URL the menu offers to
    /// copy are found the same way and can never disagree about where a message points.
    static func webLinks(in text: String, limit: Int = MessageContentParser.maximumLinksListed) -> [URL] {
        var found: [URL] = []
        var remainder = Substring(text)

        while found.count < limit, let range = remainder.range(of: "http", options: .caseInsensitive) {
            let candidate = remainder[range.lowerBound...]
            guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://") else {
                let skipTo = remainder.index(range.lowerBound, offsetBy: 4, limitedBy: remainder.endIndex) ?? remainder.endIndex
                remainder = remainder[skipTo...]
                continue
            }
            let end = candidate.firstIndex { $0.isWhitespace || $0 == ")" || $0 == ">" } ?? candidate.endIndex
            var urlText = candidate[candidate.startIndex..<end]
            while let last = urlText.last, ".,;:!?]".contains(last) {
                urlText = urlText.dropLast()
            }
            if let url = URL(string: String(urlText)), url.isWebLink { found.append(url) }
            remainder = remainder[urlText.endIndex...]
        }
        return found
    }

    /// Finds bare `http(s)://` URLs in plain text so they become real links.
    ///
    /// Markdown segments are handed to the Markdown renderer untouched, which already
    /// handles `[text](url)` and autolinks.
    static func linkify(_ text: String, isMarkdown: Bool) -> [InlineNode] {
        if isMarkdown { return [.markdown(text)] }

        var nodes: [InlineNode] = []
        var remainder = Substring(text)

        while let range = remainder.range(of: "http", options: .caseInsensitive) {
            let candidate = remainder[range.lowerBound...]
            guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://") else {
                let skipTo = remainder.index(range.lowerBound, offsetBy: 4, limitedBy: remainder.endIndex) ?? remainder.endIndex
                nodes.append(.text(String(remainder[remainder.startIndex..<skipTo])))
                remainder = remainder[skipTo...]
                continue
            }

            let end = candidate.firstIndex { $0.isWhitespace } ?? candidate.endIndex
            var urlText = candidate[candidate.startIndex..<end]
            // Don't swallow sentence punctuation that merely follows the link.
            while let last = urlText.last, ".,;:!?)]".contains(last) {
                urlText = urlText.dropLast()
            }

            let prefix = remainder[remainder.startIndex..<range.lowerBound]
            if !prefix.isEmpty { nodes.append(.text(String(prefix))) }

            if let url = URL(string: String(urlText)), url.isWebLink {
                nodes.append(.link(url: url, label: String(urlText)))
            } else {
                nodes.append(.text(String(urlText)))
            }
            remainder = remainder[urlText.endIndex...]
        }

        if !remainder.isEmpty { nodes.append(.text(String(remainder))) }
        return nodes
    }

    // MARK: - Block splitting

    enum RawBlock: Sendable, Equatable {
        case paragraph(String)
        case code(String, language: String?)
        case quote([String])
        case list(isOrdered: Bool, items: [String])
    }

    /// Splits fenced code, block quotes and lists out of the message.
    ///
    /// Everything else stays a paragraph with its newlines intact — chat messages use
    /// single line breaks to mean line breaks, unlike documents.
    static func splitBlocks(_ text: String, allowMarkdown: Bool) -> [RawBlock] {
        guard allowMarkdown else {
            return text.isEmpty ? [] : [.paragraph(text)]
        }

        var blocks: [RawBlock] = []
        var paragraph: [String] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraph = []
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoted = [String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1))]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
                    lines = lines.dropFirst()
                    quoted.append(String(next.dropFirst(next.hasPrefix("> ") ? 2 : 1)))
                }
                blocks.append(.quote(quoted))
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                var items = [item.text]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces),
                      let following = listItem(next), following.isOrdered == item.isOrdered {
                    lines = lines.dropFirst()
                    items.append(following.text)
                }
                blocks.append(.list(isOrdered: item.isOrdered, items: items))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()

        return blocks
    }

    private static func listItem(_ line: String) -> (text: String, isOrdered: Bool)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(line.dropFirst(2)), false)
        }
        // `1. `, `2) ` …
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (String(rest.dropFirst(2)), true)
            }
        }
        return nil
    }
}
