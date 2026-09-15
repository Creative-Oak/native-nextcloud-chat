import SwiftUI

/// The fill a message sits in: the accent when it's yours, a quiet wash when it isn't.
///
/// Shared, because two things wear it — the bubble around an ordinary message, and the
/// small one a caption gets under a picture.
struct MessageBubble: ViewModifier {
    var isFromMe: Bool
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .foregroundStyle(isFromMe ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// Opacity on `primary` rather than a fixed grey, so it inverts with the theme.
    private var fill: AnyShapeStyle {
        isFromMe ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.09))
    }
}

extension View {
    func messageBubble(isFromMe: Bool, cornerRadius: CGFloat = 16) -> some View {
        modifier(MessageBubble(isFromMe: isFromMe, cornerRadius: cornerRadius))
    }
}
