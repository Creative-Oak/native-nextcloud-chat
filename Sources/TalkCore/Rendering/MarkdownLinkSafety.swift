import Foundation

/// A run with no link is not a refused one. Everything else is measured against the single
/// allowlist, ``Foundation/URL/isWebLink`` — a second list kept next to the thing it guards
/// is a list that drifts.
private func isRefusedLink(_ url: URL?) -> Bool {
    guard let url else { return false }
    return !url.isWebLink
}

extension AttributedString {
    /// The same string, minus every link whose destination this app would refuse to open.
    ///
    /// Foundation's Markdown parser makes a `.link` run out of anything it can build a
    /// `URL` from — `smb:`, `file:` and `shortcuts:` included — and it does that at render
    /// time, from the source text, after everything ``MessageContentParser`` decided. No
    /// amount of sanitising the parsed nodes upstream reaches it. So the rule
    /// ``MessageContentParser/linkify(_:isMarkdown:)`` applies to plain text is applied
    /// here to what the Markdown parser found: a destination that is not a web link is not
    /// a link.
    ///
    /// It lives in the core rather than beside the view that calls it because it is the
    /// whole of the fix, and a fix in the app target is a fix nothing runs: that target has
    /// no unit tests, and the stand-in `AttributedString(markdown:options:)` the Linux
    /// type-check builds against produces no link attributes at all, so a mistake here
    /// would leave CI green. `AttributedString` and its `.link` attribute are Foundation
    /// rather than SwiftUI, so the decision can be made — and checked — here.
    ///
    /// Stripping the *attribute* rather than the syntax is what makes this indifferent to
    /// which construct produced it: an inline link, an autolink `<smb://host/x>`, a
    /// reference-style link, a link inside a list item or a block quote all arrive as a run
    /// carrying a `.link`, and all leave without one.
    var withoutRefusedLinks: AttributedString {
        guard runs.contains(where: { isRefusedLink($0.link) }) else { return self }

        // Rebuilt rather than edited in place: mutating an `AttributedString` while walking
        // its own runs is the kind of thing that works until it doesn't.
        var cleaned = AttributedString()
        for run in runs {
            var piece = AttributedString(self[run.range])
            if isRefusedLink(piece.link) { piece.link = nil }
            cleaned.append(piece)
        }
        return cleaned
    }
}
