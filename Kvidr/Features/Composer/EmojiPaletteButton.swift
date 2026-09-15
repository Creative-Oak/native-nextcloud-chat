import AppKit
import SwiftUI

/// The system emoji palette, which inserts straight into whatever has focus — the same thing
/// Messages' smiley opens.
///
/// Shared by both composers. The focus is moved first and the palette asked for on the next
/// turn, so it lands in the field beside this button rather than in whatever had focus a
/// moment ago.
struct EmojiPaletteButton: View {
    /// Set true before the palette opens, so it inserts where you expect.
    var focus: () -> Void

    var body: some View {
        Button {
            focus()
            Task { @MainActor in NSApplication.shared.orderFrontCharacterPalette(nil) }
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 17, weight: .regular))
                .frame(width: GlassMetrics.control, height: GlassMetrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassCircle()
        .help("Emoji")
        .accessibilityLabel("Emoji")
    }
}
