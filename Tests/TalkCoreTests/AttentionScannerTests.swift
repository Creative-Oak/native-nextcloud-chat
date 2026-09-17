import Foundation
import Testing
@testable import TalkCore

/// What earns a conversation the "needs you" mark in the sidebar, without a model.
@Suite("Attention")
struct AttentionScannerTests {
    @Test("A question is waiting on you")
    func questions() {
        #expect(AttentionScanner.read("Kan du nå at kigge på rapporten inden fredag?") == .asksYou)
        #expect(AttentionScanner.read("hvornår passer det dig?") == .asksYou)
        #expect(AttentionScanner.read("are we still on for tomorrow?") == .asksYou)
    }

    @Test("A request without a question mark is too")
    func requests() {
        #expect(AttentionScanner.read("Kan du lige sende mig tallene") == .asksYou)
        #expect(AttentionScanner.read("Husk at få den godkendt inden på fredag") == .asksYou)
        #expect(AttentionScanner.read("please take a look when you get a minute") == .asksYou)
        #expect(AttentionScanner.read("let me know how it goes") == .asksYou)
    }

    @Test("Talk's own mention flag settles it on its own")
    func mentions() {
        #expect(AttentionScanner.read("her er filen", mentionsYou: true) == .asksYou)
        // Even an acknowledgement, if it named you, was aimed at you.
        #expect(AttentionScanner.read("tak!", mentionsYou: true) == .asksYou)
    }

    @Test("Closing a loop is not opening one")
    func acknowledgements() {
        #expect(AttentionScanner.read("ok") == .ignorable)
        #expect(AttentionScanner.read("Tak!") == .ignorable)
        #expect(AttentionScanner.read("ja, det lyder godt") == .ignorable)
        #expect(AttentionScanner.read("👍") == .ignorable)
        #expect(AttentionScanner.read("perfekt, tak") == .ignorable)
        #expect(AttentionScanner.read("sounds good") == .ignorable)
        #expect(AttentionScanner.read("") == .ignorable)
        // "ok?" is somebody agreeing, not somebody asking.
        #expect(AttentionScanner.read("ok?") == .ignorable)
    }

    @Test("Everything else waits for a second opinion")
    func unclear() {
        #expect(AttentionScanner.read("jeg har lagt den i mappen") == .unclear)
        #expect(AttentionScanner.read("mødet er flyttet til på fredag") == .unclear)
        #expect(AttentionScanner.read("I pushed the fix to main") == .unclear)
        // Long and agreeable is not an acknowledgement — it may still carry something.
        #expect(AttentionScanner.read("ja godt, men jeg tror vi skal kigge på den igen inden vi sender den") == .unclear)
    }
}
