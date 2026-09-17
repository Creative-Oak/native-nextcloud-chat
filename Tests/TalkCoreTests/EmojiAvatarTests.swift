import Foundation
import Testing
@testable import TalkCore

@Suite("Emoji conversation pictures")
struct EmojiAvatarTests {
    @Test("Talk's emoji SVG gives up its colour and its emoji")
    func parses() throws {
        let svg = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <svg width="512" height="512" version="1.1" viewBox="0 0 500 500" xmlns="http://www.w3.org/2000/svg">
            <rect width="100%" height="100%" fill="#6B9E82"></rect>
            <text x="50%" y="330" style="font-size:240px;font-family:'Noto Color Emoji';text-anchor:middle;">💾</text>
        </svg>
        """
        let avatar = try #require(EmojiAvatar.parse(Data(svg.utf8)))
        #expect(avatar.fillHex == "6b9e82")
        #expect(avatar.emoji == "💾")
        #expect(abs(avatar.rgb.green - 158.0 / 255) < 0.001)
    }

    @Test("An emoji written as a character reference is read too; a picture is left alone")
    func entitiesAndPictures() {
        let svg = ##"<svg><rect fill="#fff"/><text>&#x1F680;</text></svg>"##
        #expect(EmojiAvatar.parse(Data(svg.utf8)) == EmojiAvatar(fillHex: "ffffff", emoji: "🚀"))
        #expect(EmojiAvatar.parse(Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(EmojiAvatar.parse(Data(##"<svg><rect fill="#fff"/><text>A long name</text></svg>"##.utf8)) == nil)
    }
}
