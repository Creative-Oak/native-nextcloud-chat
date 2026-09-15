import AppKit
import SwiftUI
import Synchronization

/// A paragraph of inline runs, as one selectable `Text`, whose links show the pointing
/// hand under the pointer — and nothing else: no underline, ever, the way Messages does
/// it.
///
/// A `Text` gives nothing away about where its runs ended up, and the one API that does,
/// a text renderer, is bypassed the moment selection is enabled: SwiftUI hands the
/// drawing to its selection overlay and never calls the renderer. So the visible text is
/// left alone, and an invisible twin of it — same runs, same width, therefore the same
/// layout — is drawn behind it with a renderer that does nothing but note where the link
/// runs landed. The pointer is checked against those, and that decides the cursor.
struct InlineText: View {
    let nodes: [InlineNode]
    let isFromMe: Bool

    @Environment(\.isTranscriptScrolling) private var isScrolling
    @State private var hovered: LinkRunFrame?
    @State private var frames = LinkRunFrames()

    var body: some View {
        let attributed = MessageAttributedString.make(nodes, isFromMe: isFromMe)
        let text = Self.text(from: attributed)

        if attributed.runs.contains(where: { $0.link != nil }) {
            text
                // Selection is enabled here, on the visible text alone, rather than
                // by the caller: it is inherited by every `Text` inside, and a
                // selectable twin is drawn by the selection overlay, not its renderer.
                .textSelection(.enabled)
                .background {
                    // The twin. Drawn in clear, so the renderer runs and nothing shows.
                    text
                        .textRenderer(LinkRunRecorder(frames: frames))
                        .textSelection(.disabled)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        // Rows sliding under a stationary pointer would otherwise
                        // re-evaluate every paragraph they pass through.
                        guard !isScrolling else { return }
                        let hit = frames.current.first { $0.rect.contains(point) }
                        if hit != hovered {
                            hovered = hit
                            setCursor(overLink: hit != nil)
                        }
                    case .ended:
                        if hovered != nil {
                            hovered = nil
                            setCursor(overLink: false)
                        }
                    }
                }
                .help(hoveredDestination)
        } else {
            text
                .textSelection(.enabled)
        }
    }

    /// Where the link under the pointer actually goes.
    ///
    /// A link here has no underline and its label is whatever the sender typed, so without
    /// this there is nothing at all to tell `[cloud.acme.example](https://evil.tld)` from
    /// the page it claims to be — not a status bar, not a menu item, not the label. The
    /// frames the renderer records for the cursor already say which run the pointer is
    /// over; this is the same answer, in words. ``LinkPreviewCard`` has shown its
    /// destination like this all along, and an inline link is the one that needs it most.
    private var hoveredDestination: String {
        guard let url = hovered?.url else { return "" }
        let text = url.absoluteString
        // A tooltip that runs off the edge of the screen shows nobody anything.
        return text.count > 180 ? String(text.prefix(180)) + "…" : text
    }

    /// The pointing hand over the link run itself, and the arrow back once off it — set
    /// outright, since the selectable text underneath has an I-beam of its own that a
    /// pointer style does not get past. Only on the change, so a still pointer is not
    /// fought over on every move.
    private func setCursor(overLink: Bool) {
        (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// A paragraph is a paragraph. Each run below wraps the whole accumulated result, so
    /// the tree is as deep as the paragraph has runs, and SwiftUI walks it recursively to
    /// resolve it, again to lay it out, and again to draw the invisible twin. Four
    /// thousand emphasis runs fit inside Talk's message limit; past this many the message
    /// is a shape rather than a sentence, and the tail is drawn as one plain run instead.
    /// Every word is still there — only the emphasis on the end of it is lost.
    private static let maximumRuns = 512

    /// The paragraph, run by run, with each link run tagged with its destination for the
    /// renderer. Built by concatenation because a marker attribute can only be attached to
    /// a `Text`, not to a run of an `AttributedString`.
    private static func text(from attributed: AttributedString) -> Text {
        var result = Text(verbatim: "")
        var remaining = maximumRuns
        var tail: AttributedString.Index?

        for run in attributed.runs {
            guard remaining > 0 else {
                tail = run.range.lowerBound
                break
            }
            remaining -= 1
            let piece = Text(AttributedString(attributed[run.range]))
            let tagged = run.link.map { piece.customAttribute(LinkRun(url: $0)) } ?? piece
            // Interpolation is how two `Text`s are joined now; `+` is deprecated.
            result = Text("\(result)\(tagged)")
        }

        if let tail {
            let rest = Text(verbatim: String(attributed[tail..<attributed.endIndex].characters))
            result = Text("\(result)\(rest)")
        }
        return result
    }
}

/// Marks a run as a link and carries where it goes, so the renderer can tell it from the
/// words around it and the view can say what it found.
private struct LinkRun: TextAttribute {
    let url: URL
}

/// Where one link run landed, and what it points at.
private struct LinkRunFrame: Equatable {
    var rect: CGRect
    var url: URL
}

/// The frames the renderer found, shared with the view. A lock rather than a `@State`
/// write, because a renderer draws whenever SwiftUI likes and must not touch view state.
private final class LinkRunFrames: Sendable {
    private let storage = Mutex<[LinkRunFrame]>([])

    var current: [LinkRunFrame] {
        storage.withLock { $0 }
    }

    func replace(with frames: [LinkRunFrame]) {
        storage.withLock { $0 = frames }
    }
}

private struct LinkRunRecorder: TextRenderer {
    let frames: LinkRunFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var found: [LinkRunFrame] = []
        for line in layout {
            for run in line {
                if let link = run[LinkRun.self] {
                    let bounds = run.typographicBounds
                    found.append(LinkRunFrame(rect: bounds.rect, url: link.url))
                }
                context.draw(run)
            }
        }
        frames.replace(with: found)
    }
}
