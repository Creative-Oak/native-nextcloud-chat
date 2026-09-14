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
        case .compact: 72
        case .standard: 280
        }
    }

    /// The face in a compact row. Sized so the row is the sidebar's own selection
    /// highlight with a little air around it, at `compact`'s width.
    static let compactAvatarSize: CGFloat = 38

    /// Which width a divider dragged to `width` is nearer to. The halfway point, no
    /// hysteresis: the switch is visible enough to be its own feedback.
    static func nearest(toWidth width: CGFloat) -> SidebarMode {
        width < (compact.width + standard.width) / 2 ? .compact : .standard
    }

    mutating func toggle() {
        self = self == .compact ? .standard : .compact
    }
}
