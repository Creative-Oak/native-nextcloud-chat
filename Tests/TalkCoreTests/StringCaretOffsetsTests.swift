import Foundation
import Testing
@testable import TalkCore

/// AppKit's text view counts UTF-16 code units; `MentionComposer` counts `Character`s.
/// These conversions are what keeps the composer's caret and its mention detection talking
/// about the same place in the line once a message contains an emoji — which, in a chat
/// app, is most of them.
@Suite("Caret offsets")
struct StringCaretOffsetsTests {
    @Test("Plain ASCII maps one to one")
    func ascii() {
        let text = "hello @al"
        for offset in 0...text.utf16.count {
            #expect(text.characterOffset(forUTF16Offset: offset) == offset)
            #expect(text.utf16Offset(forCharacterOffset: offset) == offset)
        }
    }

    @Test("An emoji is one character and two UTF-16 units")
    func emoji() {
        let text = "👍 @al"
        #expect(text.count == 5)
        #expect(text.utf16.count == 6)
        #expect(text.characterOffset(forUTF16Offset: 6) == 5)
        #expect(text.utf16Offset(forCharacterOffset: 5) == 6)
        // The caret just after the emoji: AppKit says 2, the mention logic needs 1.
        #expect(text.characterOffset(forUTF16Offset: 2) == 1)
        #expect(text.utf16Offset(forCharacterOffset: 1) == 2)
    }

    @Test("Combining marks count as one character too")
    func combiningMarks() {
        let text = "cafe\u{301} @b"
        #expect(text.count == 7)
        #expect(text.utf16.count == 8)
        #expect(text.characterOffset(forUTF16Offset: text.utf16.count) == text.count)
    }

    @Test("Every character boundary round-trips")
    func roundTrip() {
        let text = "a👍b 🇩🇰 é@x"
        for offset in 0...text.count {
            let utf16 = text.utf16Offset(forCharacterOffset: offset)
            #expect(text.characterOffset(forUTF16Offset: utf16) == offset)
        }
    }

    @Test("A caret inside a surrogate pair rounds down rather than trapping")
    func insideSurrogatePair() {
        let text = "👍a"
        // Offset 1 is the middle of the emoji — not a character position at all.
        #expect(text.characterOffset(forUTF16Offset: 1) == 0)
    }

    @Test("Out-of-range offsets are clamped, not trapped")
    func outOfRange() {
        let text = "👍"
        #expect(text.characterOffset(forUTF16Offset: -5) == 0)
        #expect(text.characterOffset(forUTF16Offset: 99) == 1)
        #expect(text.utf16Offset(forCharacterOffset: -5) == 0)
        #expect(text.utf16Offset(forCharacterOffset: 99) == 2)
    }

    @Test("A mention typed after an emoji is still found")
    func mentionAfterEmoji() {
        let text = "👍 @al"
        // What AppKit reports with the caret at the end of the line.
        let appKitCaret = text.utf16.count
        let caret = text.characterOffset(forUTF16Offset: appKitCaret)

        let query = try! #require(MentionComposer.activeQuery(in: text, caret: caret))
        #expect(query.text == "al")

        let result = MentionComposer.apply(
            MentionSuggestion(id: "alice", label: "Alice", mentionID: "alice", source: .users),
            to: text,
            replacing: query
        )
        #expect(result.text == "👍 @alice ")
        // And the caret handed back to AppKit lands after the trailing space, not inside
        // the emoji.
        #expect(result.text.utf16Offset(forCharacterOffset: result.caret) == result.text.utf16.count)
    }
}
