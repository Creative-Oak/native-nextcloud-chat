import Foundation

/// The sidebar's two widths, as in Messages: the full list, or a column of faces.
///
/// Two, not a range. The column is pinned to whichever of these is current — see
/// `RootView` — and dragging the divider chooses between them rather than moving it, which
/// is what `SidebarDividerTracker` turns the drag into. That is the whole reason the widths
/// live here as named cases rather than as a `min`/`max` on the column: a sidebar that can
/// be any width in between has to lay its rows out for every one of them, and the
/// half-clipped rows that gives are exactly what Messages avoids by snapping.
enum SidebarMode: String, CaseIterable, Sendable {
    case compact
    case standard

    var width: CGFloat {
        switch self {
        case .compact: 94
        case .standard: 280
        }
    }

    // The compact column is Messages', measured: a 94pt column of faces on an 80pt pitch,
    // each with its name beneath and its selection highlight close to a square.

    /// The face in a compact row, with room under it for the name.
    static let compactAvatarSize: CGFloat = 36

    /// A compact row's height — the selection highlight's.
    static let compactRowHeight: CGFloat = 72

    /// The air between compact rows, split above and below each as its list row insets.
    static let compactRowSpacing: CGFloat = 8

    /// Which width a divider dragged to `width` is nearer to. The halfway point, no
    /// hysteresis: the switch is visible enough to be its own feedback.
    static func nearest(toWidth width: CGFloat) -> SidebarMode {
        width < (compact.width + standard.width) / 2 ? .compact : .standard
    }

    mutating func toggle() {
        self = self == .compact ? .standard : .compact
    }
}
