import Foundation
import Testing
@testable import TalkCore

/// The link a preview card is made for.
struct LinkPreviewTests {
    private let parser = MessageContentParser(currentUserID: "alice")

    @Test("A bare URL in plain text is the first web link")
    func plainText() {
        let content = parser.parse(text: "Se lige https://www.theverge.com/policy/994414/cities-ditching-flock-cameras-controversy her", parameters: [:], isMarkdown: false)
        #expect(content.firstWebLink?.host() == "www.theverge.com")
    }

    @Test("A bare URL in a Markdown message is the first web link")
    func markdown() {
        let content = parser.parse(text: "https://www.theverge.com/policy/994414/cities-ditching-flock-cameras-controversy", parameters: [:], isMarkdown: true)
        #expect(content.firstWebLink?.host() == "www.theverge.com")
        let multi = parser.parse(text: "Hej.\nSe lige denne VATTENKAR fra IKEA.\nhttps://applink.ikea.com/tY8M9r9M4w--80541565--dk--da", parameters: [:], isMarkdown: true)
        #expect(multi.firstWebLink?.host() == "applink.ikea.com")
    }

    @Test("Markdown link syntax yields the target, without the closing bracket")
    func markdownLink() {
        let content = parser.parse(text: "See [the article](https://example.com/a/b) now.", parameters: [:], isMarkdown: true)
        #expect(content.firstWebLink == URL(string: "https://example.com/a/b"))
    }

    @Test("No link, no preview")
    func none() {
        let content = parser.parse(text: "Nothing to see here", parameters: [:], isMarkdown: true)
        #expect(content.firstWebLink == nil)
    }
}
