import Foundation
import Testing
@testable import TalkCore

struct KvidrLinkTests {
    private func link(_ string: String) -> KvidrLink? {
        URL(string: string).flatMap(KvidrLink.init)
    }

    @Test func linksSayWhatToOpen() {
        #expect(link("kvidr://open?conversation=Budget%20team") == .open(conversation: "Budget team"))
        #expect(link("kvidr://open?token=abc123") == .open(conversation: "abc123"))
        #expect(link("kvidr:open?name=Anna") == .open(conversation: "Anna"))
        #expect(link("kvidr://catch-up") == .catchUp)
        #expect(link("kvidr://search?q=invoice") == .search("invoice"))
    }

    @Test func composingFillsTheFieldAndNeverSends() {
        #expect(link("kvidr://compose?conversation=Anna&text=Running%20late") == .compose(conversation: "Anna", text: "Running late"))
        // There's no way to say "send": such a link is nothing.
        #expect(link("kvidr://send?conversation=Anna&text=hi") == nil)
        #expect(link("kvidr://call?conversation=Anna") == nil)
    }

    @Test func incompleteOrForeignLinksAreNothing() {
        #expect(link("kvidr://open") == nil)
        #expect(link("kvidr://search?q=%20") == nil)
        #expect(link("https://open?conversation=x") == nil)
    }
}
