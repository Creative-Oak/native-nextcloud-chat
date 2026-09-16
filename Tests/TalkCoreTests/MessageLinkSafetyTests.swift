import Foundation
import Testing
@testable import TalkCore

/// What a message is allowed to make the app do.
///
/// Everything here is about the same two facts: the text of a message is written by
/// somebody else, and `messageParameters` is written by the server. Neither gets to pick a
/// URL scheme, reorder the words around itself, or decide how many views the transcript
/// draws.
@Suite("Message link safety")
struct MessageLinkSafetyTests {
    private let parser = MessageContentParser(currentUserID: "alice")

    private func isWebLink(_ string: String) -> Bool {
        URL(string: string)?.isWebLink ?? false
    }

    private func isOpenable(_ string: String) -> Bool {
        URL(string: string)?.isOpenableLink ?? false
    }

    // MARK: - The scheme allowlist

    @Test("Only http and https are web links")
    func schemesAllowed() {
        #expect(isWebLink("https://cloud.example.com/s/Q3-deck"))
        #expect(isWebLink("http://example.com"))
        // A scheme is case-insensitive, and so is the answer.
        #expect(isWebLink("HTTPS://example.com/a"))
        #expect(isWebLink("HtTp://example.com/a"))
    }

    @Test("Every other scheme a message could name is refused")
    func schemesRefused() {
        let refused = [
            "smb://198.51.100.7/public/deck",
            "afp://198.51.100.7/public",
            "file:///Applications/Calculator.app",
            "shortcuts://run-shortcut?name=Wipe%20Downloads",
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "JAVASCRIPT:alert(document.domain)",
            "x-apple.systempreferences:com.apple.preference.security",
            "zoommtg://zoom.us/join?confno=1234567890",
            "vnc://198.51.100.7",
            "ftp://198.51.100.7/pub",
            "data:text/html;base64,PHNjcmlwdD4=",
            "mailto:someone@example.com",
            "tel:+4512345678"
        ]
        for string in refused {
            #expect(!isWebLink(string), "\(string) must not be a web link")
        }
    }

    @Test("A URL with no scheme or no host is not a web link")
    func incompleteURLs() {
        // Scheme-relative: no scheme at all, so nothing says this would be fetched.
        #expect(!isWebLink("//evil.tld/x"))
        #expect(!isWebLink("/just/a/path"))
        #expect(!isWebLink("evil.tld/x"))
        #expect(!isWebLink("https://"))
        #expect(!isWebLink("https:///path"))
    }

    @Test("Credentials in the authority are refused, because they hide the real host")
    func credentialsInAuthority() {
        #expect(!isWebLink("https://cloud.acme.example@evil.tld/settings"))
        #expect(!isWebLink("https://user:secret@evil.tld/"))
    }

    // MARK: - Rich objects

    // MARK: - What a click is allowed to hand to the system

    @Test("Writing to a person is openable, though it is not a web link")
    func addressSchemesAreOpenable() {
        // The distinction the two predicates exist to keep: openable, never fetchable.
        for string in ["mailto:someone@example.com", "MAILTO:someone@example.com",
                       "tel:+4512345678", "TEL:+4512345678",
                       "mailto:a@example.com?subject=Invoice"] {
            #expect(isOpenable(string), "\(string) should be openable")
            #expect(!isWebLink(string), "\(string) must still not be a web link")
        }
    }

    @Test("Widening the open list did not widen anything else")
    func openingDoesNotAdmitTheRest() {
        // Every scheme the allowlist exists to stop is still stopped at the click, and a
        // scheme that addresses nobody is not worth opening either.
        for string in ["smb://198.51.100.7/public/deck",
                       "file:///Applications/Calculator.app",
                       "shortcuts://run-shortcut?name=Wipe%20Downloads",
                       "javascript:alert(1)",
                       "data:text/html;base64,PHNjcmlwdD4=",
                       "x-apple.systempreferences:com.apple.preference.security",
                       "mailto:", "tel:"] {
            #expect(!isOpenable(string), "\(string) must not be openable")
        }
    }

    @Test("Everything openable as a web link is still openable")
    func webLinksRemainOpenable() {
        for string in ["https://cloud.example.com/s/Q3-deck", "http://example.com", "HTTPS://example.com/a"] {
            #expect(isOpenable(string))
        }
        // And what `isWebLink` refuses inside http(s) it still refuses here.
        #expect(!isOpenable("https://cloud.example.com@evil.tld/"))
    }

    @Test("A rich object whose link is not a web link has no link at all")
    func richObjectLinkIsValidated() {
        func object(_ link: String) -> RichObject {
            RichObject(type: .file, id: "1", name: "Q3 Report.pdf", attributes: ["link": link])
        }
        #expect(object("file:///System/Applications/Utilities/Terminal.app").link == nil)
        #expect(object("smb://198.51.100.7/payroll/Contract.pdf").link == nil)
        #expect(object("shortcuts://run-shortcut?name=x").link == nil)
        #expect(object("https://cloud.example.com/f/9921").link?.absoluteString == "https://cloud.example.com/f/9921")
    }

    @Test("A highlight with a hostile link renders as text rather than as something to click")
    func highlightWithHostileLink() {
        let content = parser.parse(
            text: "Signed and ready: {object0}",
            parameters: [
                "object0": RichObject(
                    type: .highlight,
                    id: "1",
                    name: "https://cloud.acme.example/f/9921",
                    attributes: ["link": "smb://198.51.100.7/payroll/Contract.pdf"]
                )
            ],
            isMarkdown: false
        )
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes.count == 2)
        #expect(nodes[1] == .text("https://cloud.acme.example/f/9921"))
    }

    @Test("A highlight with an ordinary link still links")
    func highlightWithWebLink() {
        let content = parser.parse(
            text: "{object0}",
            parameters: [
                "object0": RichObject(
                    type: .highlight,
                    id: "1",
                    name: "The deck",
                    attributes: ["link": "https://cloud.example.com/s/Q3"]
                )
            ],
            isMarkdown: false
        )
        guard case .paragraph(let nodes) = content.blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(nodes[0] == .link(url: URL(string: "https://cloud.example.com/s/Q3")!, label: "The deck"))
    }

    // MARK: - Invisible characters

    @Test("Bidirectional overrides and zero-width characters are removed from displayed text")
    func invisibleMarksAreRemoved() {
        #expect("invoice\u{202E}fdp.exe".withoutInvisibleMarks == "invoicefdp.exe")
        #expect("\u{202A}a\u{202C}b".withoutInvisibleMarks == "ab")
        #expect("\u{2066}a\u{2069}b".withoutInvisibleMarks == "ab")
        #expect("IT Helpdesk\u{200B}\u{200B}".withoutInvisibleMarks == "IT Helpdesk")
        #expect("a\u{200C}b".withoutInvisibleMarks == "ab")
        #expect("a\u{200E}b\u{200F}c".withoutInvisibleMarks == "abc")
        #expect("\u{FEFF}Magnus".withoutInvisibleMarks == "Magnus")
        // A zero-width joiner between two letters hides a seam; between two pictographs it
        // spells one emoji, and a cheerful name is not an attack.
        #expect("A\u{200D}B".withoutInvisibleMarks == "AB")
        #expect("Magnus 👨‍👩‍👧".withoutInvisibleMarks == "Magnus 👨‍👩‍👧")
        #expect("Nurse 👩‍⚕️".withoutInvisibleMarks == "Nurse 👩‍⚕️")
        // Ordinary text is returned untouched.
        #expect("Magnus Holm".withoutInvisibleMarks == "Magnus Holm")
        #expect("Ærø — naïve ☺️".withoutInvisibleMarks == "Ærø — naïve ☺️")
    }

    @Test("A display name cannot reverse the sentence it is mentioned in")
    func mentionLabelIsCleaned() {
        let mention = Mention(kind: .user, id: "mallory", label: "Magnus Holm\u{202E}", isCurrentUser: false)
        #expect(mention.displayLabel == "@Magnus Holm")

        let content = parser.parse(
            text: "{mention-user1} please approve",
            parameters: ["mention-user1": RichObject(type: .user, id: "mallory", name: "IT Helpdesk\u{200B}")],
            isMarkdown: false
        )
        #expect(content.preview == "@IT Helpdesk please approve")
    }

    @Test("A one-line preview carries nothing invisible into the sidebar or a notification")
    func previewIsCleaned() {
        let content = parser.parse(
            text: "Look at {file}",
            parameters: ["file": RichObject(type: .file, id: "1", name: "photo\u{202E}gnp.command")],
            isMarkdown: false
        )
        #expect(!content.preview.contains("\u{202E}"))
        #expect(content.preview == "Look at photognp.command")
    }

    // MARK: - Unbounded content

    @Test("A message cannot attach more cards than the transcript will draw")
    func attachmentsAreCapped() {
        var parameters: [String: RichObject] = [:]
        for index in 0..<500 {
            let key = String(format: "f%05d", index)
            parameters[key] = RichObject(
                type: .file,
                id: "\(900_000 + index)",
                name: "a.png",
                attributes: ["mimetype": "image/png", "preview-available": "yes"]
            )
        }
        // Padding that is not an attachment must not spend the budget on the way past.
        for index in 0..<500 {
            parameters["z\(index)"] = RichObject(type: .user, id: "u\(index)", name: "Someone")
        }

        let content = parser.parse(text: "hi", parameters: parameters, isMarkdown: false)
        let attachments = content.blocks.filter { block in
            if case .attachment = block { return true } else { return false }
        }
        #expect(attachments.count == MessageContentParser.maximumTrailingAttachments)
    }

    @Test("The links a menu offers are the links the message contains, and no more of them")
    func webLinksAreListedAndCapped() {
        let content = parser.parse(
            text: "one https://a.example/1 two https://b.example/2",
            parameters: [:],
            isMarkdown: false
        )
        #expect(content.webLinks.map(\.absoluteString) == ["https://a.example/1", "https://b.example/2"])

        let many = (0..<50).map { "https://e\($0).example/x" }.joined(separator: " ")
        #expect(parser.parse(text: many, parameters: [:], isMarkdown: false).webLinks.count
                == MessageContentParser.maximumLinksListed)
    }

    @Test("A Markdown link's target is found the same way the preview card finds it")
    func webLinksInMarkdown() {
        let content = parser.parse(
            text: "See [the deck](https://a.example/1) and [the notes](https://b.example/2).",
            parameters: [:],
            isMarkdown: true
        )
        #expect(content.webLinks.map(\.absoluteString) == ["https://a.example/1", "https://b.example/2"])
        // And the first of them is still the one a preview card is made for.
        #expect(content.firstWebLink == URL(string: "https://a.example/1"))
    }

    // MARK: - Code spans

    /// A URL written in backticks is a URL somebody chose to show rather than to offer. It
    /// renders monospaced and unclickable — and it must not be fetched either, or the
    /// preview card reaches out to that address from the reader's machine as soon as the
    /// message scrolls into view, which is the one thing quoting it as text was for.
    @Test("A URL inside an inline code span is neither offered nor fetched")
    func inlineCodeIsNotALink() {
        let content = parser.parse(
            text: "run `curl https://tracker.evil.tld/beacon` when you get a chance",
            parameters: [:],
            isMarkdown: true
        )
        #expect(content.firstWebLink == nil)
        #expect(content.webLinks.isEmpty)
    }

    @Test("A link beside a code span is still found")
    func linksBesideCodeSpansSurvive() {
        let content = parser.parse(
            text: "see https://a.example/1 — `https://tracker.evil.tld/b` — and https://b.example/2",
            parameters: [:],
            isMarkdown: true
        )
        #expect(content.webLinks.map(\.absoluteString) == ["https://a.example/1", "https://b.example/2"])
        #expect(content.firstWebLink == URL(string: "https://a.example/1"))
    }

    @Test("A code span opened with two backticks can hold one, and still hides its URL")
    func longerCodeFence() {
        let content = parser.parse(
            text: "``a ` https://tracker.evil.tld/b``",
            parameters: [:],
            isMarkdown: true
        )
        #expect(content.firstWebLink == nil)
    }

    /// The failure mode to avoid is the opposite one: a stray backtick swallowing the rest
    /// of the message. Nothing closes it, so it is an ordinary character.
    @Test("An unmatched backtick hides nothing")
    func unmatchedBacktickHidesNothing() {
        let content = parser.parse(text: "almost ` https://a.example/1", parameters: [:], isMarkdown: true)
        #expect(content.firstWebLink == URL(string: "https://a.example/1"))

        let between = parser.parse(
            text: "`` one ` two https://a.example/1",
            parameters: [:],
            isMarkdown: true
        )
        #expect(between.firstWebLink == URL(string: "https://a.example/1"))
    }

    @Test("A fenced block was already excluded, and still is")
    func fencedBlocksStayExcluded() {
        let content = parser.parse(
            text: "look:\n```\ncurl https://tracker.evil.tld/beacon\n```\ndone",
            parameters: [:],
            isMarkdown: true
        )
        #expect(content.firstWebLink == nil)
    }

    // MARK: - Previews

    @Test("A preview is never fetched for an address only the reader can reach")
    func previewsRefuseLocalAddresses() {
        let refused = [
            "http://localhost:9200/_cat/indices",
            "http://127.0.0.1/",
            "http://127.1/",
            "https://192.168.1.1/",
            "http://10.0.0.5:8080/admin/",
            "http://172.16.4.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://0.0.0.0/",
            "http://[::1]/",
            "http://intranet/",
            "https://build.local/job/1",
            // The spellings of an address that do not look like one.
            "http://2130706433/",
            "http://0x7f.0x0.0x0.0x1/"
        ]
        for string in refused {
            let url = URL(string: string)
            #expect(url?.isPreviewableWebLink != true, "\(string) must not be previewed")
        }
    }

    @Test("An ordinary page still gets a preview")
    func previewsAllowOrdinaryPages() {
        #expect(URL(string: "https://www.theverge.com/policy/994414")?.isPreviewableWebLink == true)
        #expect(URL(string: "https://cloud.example.com/s/abc")?.isPreviewableWebLink == true)
    }

    @Test("Anything that is not a web link is not previewable either")
    func previewsFollowTheAllowlist() {
        #expect(URL(string: "smb://fileserver.example.com/share")?.isPreviewableWebLink != true)
        #expect(URL(string: "file:///etc/hosts")?.isPreviewableWebLink != true)
    }
}
