import SwiftUI
import Synchronization

/// A paragraph of inline runs, as one selectable `Text`, with links that underline under
/// the pointer — the one under the pointer, not every link in the paragraph, the way
/// Messages does it.
///
/// A `Text` gives nothing away about where its runs ended up, and the one API that does,
/// a text renderer, is bypassed the moment selection is enabled: SwiftUI hands the
/// drawing to its selection overlay and never calls the renderer. So the visible text is
/// left alone, and an invisible twin of it — same runs, same width, therefore the same
/// layout — is drawn behind it with a renderer that does nothing but note where the link
/// runs landed. The pointer is checked against those, and the underline is an overlay.
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
                .overlay(alignment: .topLeading) {
                    if let hovered {
                        Rectangle()
                            .fill(isFromMe ? Color.white : Color.accentColor)
                            .frame(width: hovered.rect.width, height: 1)
                            .offset(x: hovered.rect.minX, y: hovered.baseline + 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        // Rows sliding under a stationary pointer would otherwise
                        // re-evaluate every paragraph they pass through.
                        guard !isScrolling else { return }
                        let hit = frames.current.first { $0.rect.contains(point) }
                        if hit != hovered { hovered = hit }
                    case .ended:
                        hovered = nil
                    }
                }
        } else {
            text
                .textSelection(.enabled)
        }
    }

    /// The paragraph, run by run, with each link run tagged for the renderer. Built by
    /// concatenation because a marker attribute can only be attached to a `Text`, not to
    /// a run of an `AttributedString`.
    private static func text(from attributed: AttributedString) -> Text {
        var result = Text(verbatim: "")
        for run in attributed.runs {
            let piece = Text(AttributedString(attributed[run.range]))
            let tagged = run.link == nil ? piece : piece.customAttribute(LinkRun())
            // Interpolation is how two `Text`s are joined now; `+` is deprecated.
            result = Text("\(result)\(tagged)")
        }
        return result
    }
}

/// Marks a run as a link, so the renderer can tell it from the words around it.
private struct LinkRun: TextAttribute {}

/// Where one link run landed: its box, and the baseline the underline sits under.
private struct LinkRunFrame: Equatable {
    var rect: CGRect
    var baseline: CGFloat
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
                if run[LinkRun.self] != nil {
                    let bounds = run.typographicBounds
                    found.append(LinkRunFrame(rect: bounds.rect, baseline: bounds.rect.minY + bounds.ascent))
                }
                context.draw(run)
            }
        }
        frames.replace(with: found)
    }
}
