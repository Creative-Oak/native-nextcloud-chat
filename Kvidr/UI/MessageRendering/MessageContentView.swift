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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                MessageBlockView(block: block, isFromMe: isFromMe)
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
            return AttributedString(text)

        case .markdown(let source):
            // Inline-only, whitespace preserved: chat messages use single newlines to mean
            // line breaks, and a document-style parser would swallow them.
            let options = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            if let parsed = try? AttributedString(markdown: source, options: options) {
                return parsed
            }
            return AttributedString(source)

        case .mention(let mention):
            var text = AttributedString(mention.displayLabel)
            text.font = .body.weight(.medium)
            if isFromMe {
                // Nothing accent-coloured survives inside an accent bubble — including a
                // mention of yourself, which would otherwise be accent on accent.
                text.foregroundColor = .white
                if mention.isCurrentUser { text.backgroundColor = Color.white.opacity(0.22) }
            } else if mention.isCurrentUser {
                // The one piece of colour in an otherwise calm transcript.
                text.foregroundColor = .accentColor
                text.backgroundColor = Color.accentColor.opacity(0.15)
            } else {
                text.foregroundColor = .accentColor
            }
            return text

        case .link(let url, let label):
            // No underline, as in Messages: the pointer becomes the hand over a link
            // instead, which `InlineText` arranges.
            var text = AttributedString(label)
            text.link = url
            if isFromMe { text.foregroundColor = .white }
            return text

        case .code(let code):
            var text = AttributedString(code)
            text.font = .body.monospaced()
            return text

        case .object(let object):
            var text = AttributedString(object.name)
            text.font = .body.weight(.medium)
            if let link = object.link { text.link = link }
            return text
        }
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
            PollCard(pollID: pollID, question: object.name, isFromMe: isFromMe)
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
                Text(object.name)
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
        .help(object.name)
    }

    @ViewBuilder
    private var menu: some View {
        if object.isImage && object.previewAvailable {
            Button("Open Preview") { openAttachment?(object) }
        }
        if object.link != nil {
            Button("Open in Nextcloud") { open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(object.link?.absoluteString ?? "", forType: .string)
            }
        }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(object.name, forType: .string)
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
        NSWorkspace.shared.open(link)
    }
}
