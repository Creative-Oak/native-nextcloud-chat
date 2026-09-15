import AppKit
import SwiftUI

/// Renders parsed message content.
///
/// Inline runs become a single `AttributedString` per paragraph, so text selection and
/// copy behave the way they do everywhere else on the Mac — selecting across a mention and
/// the words around it works because it is one text run, not a row of separate views.
///
/// Markdown is converted with Apple's parser from the *source text* the server sent. No
/// HTML is parsed or rendered at any point.
struct MessageContentView: View {
    let content: MessageContent
    var isFromMe: Bool = false

    var body: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
            if let standalone = content.standalone {
                // The picture (or the poll) first and bare, then whatever was said about it
                // in a small bubble beneath — the arrangement Messages uses, and the reason
                // a caption no longer sits above its own photo inside a slab of accent.
                MessageBlockView(block: .attachment(standalone.object), isFromMe: isFromMe)

                if !standalone.caption.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(standalone.caption.enumerated()), id: \.offset) { _, block in
                            MessageBlockView(block: block, isFromMe: isFromMe)
                        }
                    }
                    .messageBubble(isFromMe: isFromMe, cornerRadius: 14)
                }
            } else {
                ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                    MessageBlockView(block: block, isFromMe: isFromMe)
                }
            }
        }
        // Link colour comes from the tint, not from a foregroundColor attribute — SwiftUI
        // renders `.link` runs in the tint and ignores the attribute. Setting it here is
        // also the only thing that reaches links inside parsed markdown and rich objects,
        // which never pass through the `.link` branch below at all.
        .tint(isFromMe ? Color.white : Color.accentColor)
    }
}

/// One block. A separate view rather than a `@ViewBuilder` method on ``MessageContentView``
/// because blocks nest: a quote contains blocks, which may themselves be quotes. A method
/// returning `some View` cannot recurse — its opaque type would be defined in terms of
/// itself — but a nominal view can, because `MessageBlockView` is a complete type before
/// its own `body` is ever looked at.
private struct MessageBlockView: View {
    let block: MessageBlock
    let isFromMe: Bool

    var body: some View {
        switch block {
        case .paragraph(let nodes):
            // Selectable, but `InlineText` says so itself — see there for why.
            InlineText(nodes: nodes, isFromMe: isFromMe)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let code, let language):
            CodeBlockView(code: code, language: language)

        case .quote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MessageBlockView(block: inner, isFromMe: isFromMe)
                    }
                }
                .foregroundStyle(.secondary)
            }

        case .list(let isOrdered, let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isOrdered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        InlineText(nodes: item, isFromMe: isFromMe)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .attachment(let object):
            AttachmentView(object: object, isFromMe: isFromMe)
        }
    }
}

/// The one door a URL out of a message leaves by.
///
/// `NSWorkspace.open` hands whatever it is given to LaunchServices, which will honour any
/// registered scheme: `smb:` mounts an attacker's share and asks for credentials, `file:`
/// gives a local path to whichever app claims it, `shortcuts:` runs a shortcut by name,
/// and every third-party scheme on the machine starts that app with arguments a stranger
/// chose. The sandbox constrains what *this* app reaches and does nothing about any of
/// that. So a link that came out of a message is opened here, or it is not opened.
enum MessageLink {
    @MainActor
    static func open(_ url: URL) {
        guard url.isWebLink else {
            // The URL itself is message content and does not go in the log.
            Log.ui.warning("Refused to open a message link with scheme \(url.scheme ?? "none")")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Builds the attributed string for one paragraph.
enum MessageAttributedString {
    static func make(_ nodes: [InlineNode], isFromMe: Bool) -> AttributedString {
        var result = AttributedString()
        for node in nodes {
            result.append(attributed(node, isFromMe: isFromMe))
        }
        return result
    }

    private static func attributed(_ node: InlineNode, isFromMe: Bool) -> AttributedString {
        switch node {
        case .text(let text):
            return AttributedString(text.withoutInvisibleMarks)

        case .markdown(let source):
            // Inline-only, whitespace preserved: chat messages use single newlines to mean
            // line breaks, and a document-style parser would swallow them.
            let cleaned = source.withoutInvisibleMarks
            let options = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            guard let parsed = try? AttributedString(markdown: cleaned, options: options) else {
                return AttributedString(cleaned)
            }
            return withoutRefusedLinks(parsed)

        case .mention(let mention):
            var text = AttributedString(mention.displayLabel)
            text.font = .body.weight(.medium)
            // Every mention gets a capsule, not just a mention of you. Accent-coloured
            // unadorned text is what a link looks like here, so without this `[@Magnus
            // Holm](https://evil.tld)` is a verified mention to look at and a link to
            // click. Markdown produces no background colour, so the capsule is the one
            // part of the treatment a sender cannot write.
            if isFromMe {
                // Nothing accent-coloured survives inside an accent bubble — including a
                // mention of yourself, which would otherwise be accent on accent.
                text.foregroundColor = .white
                text.backgroundColor = Color.white.opacity(mention.isCurrentUser ? 0.22 : 0.12)
            } else if mention.isCurrentUser {
                // The one piece of colour in an otherwise calm transcript.
                text.foregroundColor = .accentColor
                text.backgroundColor = Color.accentColor.opacity(0.15)
            } else {
                text.foregroundColor = .accentColor
                text.backgroundColor = Color.accentColor.opacity(0.08)
            }
            return text

        case .link(let url, let label):
            // No underline, as in Messages: the pointer becomes the hand over a link
            // instead, and `InlineText` puts the destination in a tooltip, which is the
            // only thing here that says where the words actually go.
            var text = AttributedString(label.withoutInvisibleMarks)
            if url.isWebLink { text.link = url }
            if isFromMe { text.foregroundColor = .white }
            return text

        case .code(let code):
            var text = AttributedString(code.withoutInvisibleMarks)
            text.font = .body.monospaced()
            return text

        case .object(let object):
            var text = AttributedString(object.displayName)
            text.font = .body.weight(.medium)
            // Already narrowed to a web link where it is read off the wire — see
            // ``RichObject/link``. Asked again here because this is where it becomes
            // something to click.
            if let link = object.link, link.isWebLink { text.link = link }
            return text
        }
    }

    /// The same string, minus every link the Markdown parser attached to a destination
    /// this app would refuse to open.
    ///
    /// Foundation's parser makes a `.link` run out of anything it can build a `URL` from,
    /// `smb:` and `file:` and `shortcuts:` included, and it does that at render time —
    /// after everything the parser in the core decided. Sanitising the nodes upstream
    /// would not reach it. So the rule `linkify` applies to plain text is applied here, to
    /// what the Markdown parser found: a destination that is not a web link is not a link.
    private static func withoutRefusedLinks(_ parsed: AttributedString) -> AttributedString {
        guard parsed.runs.contains(where: { isRefused($0.link) }) else { return parsed }

        // Rebuilt rather than edited in place: mutating an `AttributedString` while
        // walking its own runs is the kind of thing that works until it doesn't.
        var cleaned = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if isRefused(piece.link) { piece.link = nil }
            cleaned.append(piece)
        }
        return cleaned
    }

    private static func isRefused(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !url.isWebLink
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        .contextMenu {
            Button("Copy Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                didCopy = true
            }
        }
    }
}

/// A file, poll or location shared into the conversation.
///
/// Images show themselves; everything else gets a compact row that says what it is. The
/// alternative — a generic document icon for a photo — is the thing that makes a chat
/// client feel like a file browser.
private struct AttachmentView: View {
    let object: RichObject
    var isFromMe = false

    @Environment(\.openAttachment) private var openAttachment

    var body: some View {
        // A poll is not a file to open: it is something to take part in, so it gets a card
        // that can be voted in rather than a row that opens a viewer.
        if object.type == .talkPoll, let pollID = Int(object.id) {
            PollCard(pollID: pollID, question: object.displayName, isFromMe: isFromMe)
        } else if object.isImage && object.previewAvailable {
            InlineImageView(object: object)
                .contextMenu { menu }
        } else {
            fileRow
        }
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(object.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { open() }
        .accessibilityAddTraits(.isButton)
        .contextMenu { menu }
        // The name is what the row shows; the link is where the row goes. A file row is
        // the other place in this app where those two can disagree.
        .help(object.link.map { "\(object.displayName)\n\($0.absoluteString)" } ?? object.displayName)
    }

    @ViewBuilder
    private var menu: some View {
        if object.isImage && object.previewAvailable {
            Button("Open Preview") { openAttachment?(object) }
        }
        if let link = object.link {
            Button("Open in Nextcloud") { open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
        }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(object.displayName, forType: .string)
        }
    }

    private var symbol: String {
        switch object.type {
        case .talkPoll: "chart.bar.doc.horizontal"
        case .geoLocation: "mappin.and.ellipse"
        case .deckCard: "rectangle.stack"
        default:
            if object.isImage { "photo" }
            else if object.isVideo { "film" }
            else if object.mimeType?.contains("pdf") == true { "doc.richtext" }
            else { "doc" }
        }
    }

    private var detail: String? {
        switch object.type {
        case .talkPoll: return "Poll"
        case .geoLocation: return "Location"
        case .deckCard: return [object.boardName, object.stackName].compactMap { $0 }.joined(separator: " · ")
        default:
            guard let size = object.size else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    private func open() {
        if object.isImage && object.previewAvailable, let openAttachment {
            openAttachment(object)
            return
        }
        guard let link = object.link else { return }
        MessageLink.open(link)
    }
}
