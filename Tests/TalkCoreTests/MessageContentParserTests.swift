import Foundation
import Testing
@testable import TalkCore

@Suite("Message content parsing")
struct MessageContentParserTests {
    private let parser = MessageContentParser(currentUserID: "alice")

    private func user(_ id: String, _ name: String, server: String? = nil) -> RichObject {
        RichObject(type: .user, id: id, name: name, attributes: server.map { ["server": $0] } ?? [:])
    }

    // MARK: - Placeholders

    @Test("A mention of me is marked as such")
    func mentionOfMe() {
        let content = parser.parse(
            text: "Hi {mention-user1}, ready?",
            parameters: ["mention-user1": user("alice", "Alice Andersen")],
            isMarkdown: false
        )
        #expect(content.mentionsCurrentUser)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes.count == 3)
        #expect(nodes[0] == .text("Hi "))
        #expect(nodes[1] == .mention(Mention(kind: .user, id: "alice", label: "Alice Andersen", isCurrentUser: true)))
        #expect(nodes[2] == .text(", ready?"))
        #expect(content.preview == "Hi @Alice Andersen, ready?")
    }

    @Test("A mention of somebody else is not about me")
    func mentionOfSomeoneElse() {
        let content = parser.parse(
            text: "{mention-user1} can you look?",
            parameters: ["mention-user1": user("bob", "Bob")],
            isMarkdown: false
        )
        #expect(content.mentionsCurrentUser == false)
    }

    @Test("@all counts as a mention of me")
    func mentionEveryone() {
        let content = parser.parse(
            text: "{mention-call} lunch?",
            parameters: ["mention-call": RichObject(type: .call, id: "tok", name: "Design review", attributes: ["call-type": "group"])],
            isMarkdown: false
        )
        #expect(content.mentionsCurrentUser)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes[0] == .mention(Mention(kind: .everyone, id: "tok", label: "Design review", isCurrentUser: false)))
    }

    @Test("A display name that looks like a placeholder cannot forge a mention")
    func hostileDisplayName() {
        // If substitution were textual, this name would be re-scanned and become a mention
        // of alice. It is substituted structurally, so it stays literal text.
        let content = parser.parse(
            text: "{mention-user1} says hello",
            parameters: [
                "mention-user1": user("mallory", "{mention-user2}"),
                "mention-user2": user("alice", "Alice Andersen")
            ],
            isMarkdown: false
        )
        #expect(content.mentionsCurrentUser == false)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes[0] == .mention(Mention(kind: .user, id: "mallory", label: "{mention-user2}", isCurrentUser: false)))
        #expect(nodes.count == 2)
    }

    @Test("A placeholder with no parameter is shown verbatim rather than dropped")
    func unresolvedPlaceholder() {
        let content = parser.parse(text: "Look at {missing} please", parameters: [:], isMarkdown: false)
        #expect(content.preview == "Look at {missing} please")
    }

    @Test("Braces that aren't placeholders survive intact")
    func literalBraces() {
        let content = parser.parse(text: "use { and } freely, and ${VAR}", parameters: [:], isMarkdown: false)
        #expect(content.preview == "use { and } freely, and ${VAR}")
    }

    @Test("A federated mention keeps its home server")
    func federatedMention() {
        let content = parser.parse(
            text: "{mention-federated-user1} hi",
            parameters: ["mention-federated-user1": user("frank@other.example.com", "Frank", server: "other.example.com")],
            isMarkdown: false
        )
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        guard case .mention(let mention) = nodes[0] else { Issue.record("expected mention"); return }
        #expect(mention.kind == .federatedUser)
        #expect(mention.server == "other.example.com")
        #expect(mention.isCurrentUser == false)
    }

    @Test("Names in system messages are prose, not mentions")
    func systemMessageNames() {
        let content = parser.parse(
            text: "{actor} added {user}",
            parameters: ["actor": user("carol", "Carol"), "user": user("alice", "Alice")],
            isMarkdown: false,
            isSystem: true
        )
        #expect(content.preview == "Carol added Alice")
        // …and a system message about you does not light up as a mention.
        #expect(content.mentionsCurrentUser == false)
    }

    // MARK: - Attachments

    @Test("A bare file share becomes an attachment card")
    func fileShare() {
        let file = RichObject(type: .file, id: "12", name: "plan.pdf", attributes: ["mimetype": "application/pdf", "path": "Talk/plan.pdf"])
        let content = parser.parse(text: "{file}", parameters: ["file": file], isMarkdown: false)
        #expect(content.isAttachmentOnly)
        #expect(content.blocks == [.attachment(file)])
    }

    @Test("A captioned file keeps the caption above the card")
    func captionedFile() {
        let file = RichObject(type: .file, id: "12", name: "plan.pdf", attributes: ["mimetype": "application/pdf"])
        let content = parser.parse(text: "Here's the plan", parameters: ["file": file], isMarkdown: false)
        #expect(content.blocks.count == 2)
        #expect(content.blocks[1] == .attachment(file))
    }

    @Test("An inline file reference stays inline")
    func inlineFileReference() {
        let file = RichObject(type: .file, id: "12", name: "plan.pdf")
        let content = parser.parse(text: "See {file} for details", parameters: ["file": file], isMarkdown: false)
        #expect(content.blocks.count == 1)
        #expect(content.preview == "See plan.pdf for details")
    }

    @Test("An unknown rich object degrades to its name, never to protocol text")
    func unknownObject() {
        let object = RichObject(type: .other("quantum-widget"), id: "9", name: "Quantum widget")
        let content = parser.parse(text: "Check {object}", parameters: ["object": object], isMarkdown: false)
        #expect(content.preview == "Check Quantum widget")
        #expect(!content.preview.contains("quantum-widget"))
    }

    // MARK: - Links

    @Test("Bare URLs in plain text become links")
    func autolink() {
        let content = parser.parse(text: "see https://example.com/a?b=c now", parameters: [:], isMarkdown: false)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes.count == 3)
        #expect(nodes[1] == .link(url: URL(string: "https://example.com/a?b=c")!, label: "https://example.com/a?b=c"))
    }

    @Test("Trailing sentence punctuation isn't swallowed into the link")
    func linkPunctuation() {
        let content = parser.parse(text: "go to https://example.com.", parameters: [:], isMarkdown: false)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes[1] == .link(url: URL(string: "https://example.com")!, label: "https://example.com"))
        #expect(nodes[2] == .text("."))
    }

    @Test("Text that merely contains 'http' isn't mangled")
    func notALink() {
        let content = parser.parse(text: "the http protocol is old", parameters: [:], isMarkdown: false)
        #expect(content.preview == "the http protocol is old")
    }

    // MARK: - Markdown blocks

    @Test("A fenced code block becomes a code block, not a paragraph")
    func codeBlock() {
        let content = parser.parse(
            text: "Try:\n```swift\nlet x = 1\nprint(x)\n```\nDone",
            parameters: [:], isMarkdown: true
        )
        #expect(content.blocks.count == 3)
        #expect(content.blocks[1] == .code("let x = 1\nprint(x)", language: "swift"))
    }

    @Test("Block quotes and lists are structural, not literal characters")
    func quotesAndLists() {
        let content = parser.parse(
            text: "> quoted line\n> and more\n\n- one\n- two\n\n1. first\n2. second",
            parameters: [:], isMarkdown: true
        )
        #expect(content.blocks.count == 3)
        #expect(content.blocks[0] == .quote([.paragraph([.markdown("quoted line")]), .paragraph([.markdown("and more")])]))
        #expect(content.blocks[1] == .list(isOrdered: false, items: [[.markdown("one")], [.markdown("two")]]))
        #expect(content.blocks[2] == .list(isOrdered: true, items: [[.markdown("first")], [.markdown("second")]]))
    }

    @Test("Markdown source is passed through for inline rendering, never pre-rendered")
    func inlineMarkdownPassthrough() {
        let content = parser.parse(text: "**bold** and `code`", parameters: [:], isMarkdown: true)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes == [.markdown("**bold** and `code`")])
    }

    @Test("When the server says the message isn't Markdown, asterisks stay asterisks")
    func markdownDisabled() {
        let content = parser.parse(text: "**not bold**\n- not a list", parameters: [:], isMarkdown: false)
        #expect(content.blocks.count == 1)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes == [.text("**not bold**\n- not a list")])
    }

    @Test("Single newlines inside a chat message are preserved as line breaks")
    func preservesSoftLineBreaks() {
        let content = parser.parse(text: "line one\nline two", parameters: [:], isMarkdown: true)
        #expect(content.blocks.count == 1)
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes == [.markdown("line one\nline two")])
    }

    @Test("No HTML is ever produced, even when the message contains it")
    func htmlIsInert() {
        let content = parser.parse(
            text: "<script>alert(1)</script> <b>hi</b>",
            parameters: [:], isMarkdown: true
        )
        // It stays *source text* for the Markdown renderer; nothing in this pipeline can
        // turn it into markup, and nothing downstream renders HTML.
        #expect(content.preview.contains("<script>"))
        #expect(content.blocks.count == 1)
    }

    @Test("An empty message parses to nothing rather than an empty paragraph")
    func emptyMessage() {
        #expect(parser.parse(text: "", parameters: [:], isMarkdown: true).isEmpty)
        #expect(parser.parse(text: "   \n  ", parameters: [:], isMarkdown: true).isEmpty)
    }

    @Test("Parses the fixture message end to end")
    func parsesFixtureMessage() throws {
        let envelope = try JSONDecoder().decode(OCSEnvelope<[MessageDTO]>.self, from: try Fixture.data("messages"))
        let message = try #require(envelope.data?.first { $0.id == 9843 }?.model(token: "a1b2c3d4"))
        let content = parser.parse(message)

        #expect(content.mentionsCurrentUser)
        #expect(content.preview == "Hey @Alice Andersen, can you review budget-2026.xlsx? **Today** if possible.")
    }
}
