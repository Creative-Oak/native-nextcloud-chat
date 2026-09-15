import Foundation
import Testing
@testable import TalkCore

/// The one fix that mattered most, under test at last.
///
/// ``AttributedString/withoutRefusedLinks`` is what stops a Markdown link with an `smb:`,
/// `file:` or `shortcuts:` destination from becoming something a reader can click. It used
/// to live in the app target, which has no tests and whose Linux type-check stands in a
/// `AttributedString(markdown:options:)` that produces no link attributes at all — so a
/// mistake in it would have left CI green.
///
/// Two halves, because only one of them can run everywhere. The strip itself works on
/// attribute runs, so it can be fed strings built by hand and checked on any platform.
/// Feeding it strings that *Foundation's own Markdown parser* produced is macOS-only:
/// swift-corelibs-foundation ships `AttributedString` and its `.link` attribute, but not
/// the Markdown initializers — there is no parser on Linux to ask. The macOS CI job runs
/// `swift test` too, so that half is checked on every push as well, just not twice.
@Suite("Refused links in an attributed string")
struct MarkdownLinkSafetyTests {
    /// A run of text carrying a link, the shape Foundation's Markdown parser produces.
    private func linked(_ text: String, to destination: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.link = URL(string: destination)
        return piece
    }

    // MARK: - The strip itself

    @Test("A destination the app would not open loses its link and keeps its words", arguments: [
        "smb://198.51.100.7/public/deck",
        "afp://198.51.100.7/public",
        "file:///Applications/Calculator.app",
        "shortcuts://run-shortcut?name=Wipe%20Downloads",
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "vnc://198.51.100.7",
        "x-apple.systempreferences:com.apple.preference.security",
        // Not a scheme problem — an authority that reads as one host and resolves to another.
        "https://cloud.acme.example@evil.tld/settings"
    ])
    func stripsRefusedDestinations(_ destination: String) {
        var string = AttributedString("Open ")
        string.append(linked("the deck", to: destination))
        string.append(AttributedString(" now"))

        // The test is only worth anything if the link was there to begin with.
        let before = string.runs.filter { $0.link != nil }.count
        #expect(before == 1, "\(destination) never became a link")

        let cleaned = string.withoutRefusedLinks
        let after = cleaned.runs.filter { $0.link != nil }.count
        #expect(after == 0, "\(destination) survived the strip")
        // The words stay; only the affordance goes.
        #expect(String(cleaned.characters) == "Open the deck now")
    }

    @Test("An ordinary web link keeps its attribute", arguments: [
        "https://cloud.example.com/s/Q3-deck",
        "http://example.com/a",
        "HTTPS://example.com/a",
        "https://cloud.example.com/index.php/f/9921?dir=/Talk"
    ])
    func keepsWebLinks(_ destination: String) {
        var string = AttributedString("Open ")
        string.append(linked("the deck", to: destination))

        let cleaned = string.withoutRefusedLinks
        let kept = cleaned.runs.compactMap { $0.link }
        #expect(kept.count == 1)
        #expect(kept.first == URL(string: destination))
        #expect(String(cleaned.characters) == "Open the deck")
    }

    @Test("One refused link does not take the others with it")
    func stripsOnlyTheRefusedOne() {
        var string = AttributedString("see ")
        string.append(linked("the share", to: "smb://198.51.100.7/public"))
        string.append(AttributedString(" or "))
        string.append(linked("the page", to: "https://cloud.example.com/s/Q3"))

        let cleaned = string.withoutRefusedLinks
        let kept = cleaned.runs.compactMap { $0.link?.absoluteString }
        #expect(kept == ["https://cloud.example.com/s/Q3"])
        #expect(String(cleaned.characters) == "see the share or the page")
    }

    @Test("A string with nothing to strip comes back as it was")
    func leavesCleanStringsAlone() {
        var string = AttributedString("read ")
        string.append(linked("this", to: "https://cloud.example.com/s/Q3"))
        string.append(AttributedString(" today"))

        let cleaned = string.withoutRefusedLinks
        #expect(cleaned == string)
    }

    @Test("A string with no links at all is unchanged")
    func leavesPlainStringsAlone() {
        let string = AttributedString("just some words")
        let cleaned = string.withoutRefusedLinks
        #expect(cleaned == string)
    }

    // MARK: - The same strip, over what Foundation's Markdown parser actually makes
    //
    // macOS only: `AttributedString(markdown:)` is not part of swift-corelibs-foundation.

#if canImport(Darwin)
    /// Parsed exactly the way the transcript parses it, so what comes back is the string
    /// the view would have shown.
    private func parse(_ markdown: String) throws -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try AttributedString(markdown: markdown, options: options)
    }

    @Test("Markdown naming a refused destination produces nothing to click", arguments: [
        "[the deck](smb://198.51.100.7/public/deck)",
        "[open it](file:///Applications/Calculator.app)",
        "[run it](shortcuts://run-shortcut?name=Wipe%20Downloads)",
        "[click](javascript:alert(1))",
        "[click](JaVaScRiPt:alert(1))",
        "[click](data:text/html;base64,PHNjcmlwdD4=)",
        // An autolink, which is the same destination with no label to hide behind.
        "<smb://198.51.100.7/public>",
        "<javascript:alert(1)>",
        // Reference style: the destination is a long way from the words that carry it.
        "See [the deck][ref]\n\n[ref]: smb://198.51.100.7/public",
        // Inside a list item and inside a block quote — the transcript splits these into
        // their own nodes, and each one is parsed and stripped the same way.
        "- [the deck](smb://198.51.100.7/public)",
        "> [the deck](smb://198.51.100.7/public)",
        // And wrapped in emphasis, which puts the link attribute on a run that carries
        // other attributes too.
        "**[the deck](smb://198.51.100.7/public)**"
    ])
    func markdownRefusedDestinations(_ markdown: String) throws {
        let parsed = try parse(markdown)
        let cleaned = parsed.withoutRefusedLinks
        let left = cleaned.runs.compactMap { $0.link?.absoluteString }
        #expect(left.isEmpty, "\(markdown) left \(left) behind")
    }

    /// The parameterised test above would pass just as happily if the parser never made a
    /// link in the first place. This is the one that says it does.
    @Test("And the parser really does attach a link to a scheme the app refuses")
    func theParserReallyMakesTheLink() throws {
        let parsed = try parse("[the deck](smb://198.51.100.7/public/deck)")
        let before = parsed.runs.compactMap { $0.link?.scheme }
        #expect(before.contains("smb"))

        let cleaned = parsed.withoutRefusedLinks
        let after = cleaned.runs.compactMap { $0.link }
        #expect(after.isEmpty)
        #expect(String(cleaned.characters) == "the deck")
    }

    @Test("An ordinary Markdown link survives, destination intact", arguments: [
        "[the deck](https://cloud.example.com/s/Q3)",
        "<https://cloud.example.com/s/Q3>",
        "- [the deck](https://cloud.example.com/s/Q3)",
        "> [the deck](https://cloud.example.com/s/Q3)",
        "**[the deck](https://cloud.example.com/s/Q3)**"
    ])
    func markdownWebLinksSurvive(_ markdown: String) throws {
        let parsed = try parse(markdown)
        let cleaned = parsed.withoutRefusedLinks
        let kept = Set(cleaned.runs.compactMap { $0.link?.absoluteString })
        #expect(kept == ["https://cloud.example.com/s/Q3"])
    }

    @Test("A refused link beside an ordinary one loses only itself")
    func markdownMixed() throws {
        let parsed = try parse("[share](smb://198.51.100.7/public) and [page](https://cloud.example.com/s/Q3)")
        let cleaned = parsed.withoutRefusedLinks
        let kept = Set(cleaned.runs.compactMap { $0.link?.absoluteString })
        #expect(kept == ["https://cloud.example.com/s/Q3"])
        #expect(String(cleaned.characters) == "share and page")
    }
#endif
}
