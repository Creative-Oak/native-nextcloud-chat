import Foundation

/// Translating between AppKit's caret and the composer's.
///
/// `NSTextView` counts in UTF-16 code units; `MentionComposer` counts in `Character`s,
/// because that is what reading a line of text backwards for an `@` means. The two agree
/// on plain ASCII and part company at the first emoji — one `Character`, two UTF-16 units —
/// which in a chat app is the first message, not an edge case. Everything crossing the
/// boundary in `ComposerTextView` is converted here.
extension String {
    /// The `Character` offset for a UTF-16 offset, as AppKit reports it.
    ///
    /// A caret inside a surrogate pair has no `Character` position of its own, so it rounds
    /// down to the start of that character rather than failing.
    func characterOffset(forUTF16Offset offset: Int) -> Int {
        let clamped = min(max(offset, 0), utf16.count)
        var index = utf16.index(utf16.startIndex, offsetBy: clamped)
        while index > utf16.startIndex, index.samePosition(in: self) == nil {
            index = utf16.index(before: index)
        }
        guard let aligned = index.samePosition(in: self) else { return 0 }
        return distance(from: startIndex, to: aligned)
    }

    /// The UTF-16 offset for a `Character` offset, for handing back to AppKit.
    func utf16Offset(forCharacterOffset offset: Int) -> Int {
        let clamped = min(max(offset, 0), count)
        return index(startIndex, offsetBy: clamped).utf16Offset(in: self)
    }
}
