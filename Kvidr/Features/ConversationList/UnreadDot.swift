import AppKit
import SwiftUI

/// The unread marker on a face: a dot in the accent colour, ringed in the colour behind it
/// so it reads as sitting on top of the avatar rather than punched out of it. On a selected
/// face the colours swap, since the face sits on the selection blue.
struct UnreadDot: View {
    var isSelected = false

    var body: some View {
        Circle()
            .fill(isSelected ? Color.white : Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().stroke(
                    isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .windowBackgroundColor),
                    lineWidth: 2
                )
            }
    }
}
