import SwiftUI

/// A conversation description as Nextcloud's web interface shows it: Markdown, read. Only
/// what a description uses — headings, bullets, paragraphs and inline emphasis, code and
/// links — since a description is a paragraph or two about the room, not a document.
///
/// A stack of lines rather than one attributed string: `Text` has no hanging indent, so a
/// bullet that wrapped ran its second line back under the bullet.
struct SimpleMarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(SimpleMarkdown.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case .paragraph(let text):
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                case .gap:
                    Color.clear.frame(height: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SimpleMarkdown {
    enum Block {
        case heading(AttributedString)
        case bullet(AttributedString)
        case paragraph(AttributedString)
        /// A blank line: a little air between what it separates.
        case gap
    }

    /// Lines in, blocks out. Consecutive plain lines are one paragraph; a blank line ends it.
    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                if let last = blocks.last, !isGap(last) { blocks.append(.gap) }
            } else if let match = line.firstMatch(of: /^#{1,6}\s+(.+?)\s*#*$/) {
                flush()
                blocks.append(.heading(inline(String(match.1))))
            } else if let match = line.firstMatch(of: /^(?:[-*+]|\d{1,3}[.)])\s+(.+)$/) {
                flush()
                blocks.append(.bullet(inline(String(match.1))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        while let last = blocks.last, isGap(last) { blocks.removeLast() }
        return blocks
    }

    private static func isGap(_ block: Block) -> Bool {
        if case .gap = block { return true }
        return false
    }

    /// Emphasis, code spans and links. Only web links stay links; anything else a
    /// description says stays words.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            if let link = run.link, !link.isWebLink {
                result[run.range].link = nil
            }
        }
        return result
    }
}
