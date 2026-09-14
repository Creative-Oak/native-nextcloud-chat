import SwiftUI

/// The name capsule under the toolbar — the lower half of the Messages-style header. The
/// upper half, the face, is drawn by `ChatView` in the toolbar band above; this sits
/// directly beneath it, centred over the transcript, and opens the details.
///
/// The capsule is the control and the face is not, because the title bar band is
/// AppKit's: it takes every click there for window dragging, whatever SwiftUI has
/// drawn underneath. The capsule hangs below the band, as a bar in the transcript's
/// top safe area, and the transcript scrolls under it with the same edge fade.
struct ConversationHeader: View {
    let conversation: Conversation

    /// The bar's height, which is how far the header hangs below the toolbar. Anything
    /// else pinned to the top of the transcript starts below this.
    static let depthBelowToolbar: CGFloat = 26

    /// The face: a little bigger than the toolbar's buttons, as in Messages, and
    /// starting level with their tops.
    static let avatarSize: CGFloat = 38
    static let avatarTopInset: CGFloat = 7

    var body: some View {
        Text(conversation.displayName)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .glass(.chip)
            .frame(maxWidth: 340)
            .frame(height: Self.depthBelowToolbar, alignment: .top)
            .accessibilityLabel(conversation.displayName)
    }
}
