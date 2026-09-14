import AppKit
import SwiftUI

/// Turns a drag of the sidebar's divider into a choice between the two sidebar widths.
///
/// The divider belongs to AppKit — `NavigationSplitView` is an `NSSplitViewController`
/// underneath — and SwiftUI offers nothing for the drag itself: no gesture, no callback,
/// no snapping. The split view's delegate would offer `constrainSplitPosition`, but the
/// delegate is the controller and replacing it crashes the next layout pass. So the drag
/// is not intercepted at all. The column stays pinned to the current width (`min`, `ideal`
/// and `max` all the same, in `RootView`), which AppKit honours, and what changes is the
/// *choice* of width: while the button is down on the divider, wherever the mouse is
/// relative to the sidebar's leading edge says which width is wanted, and the column moves
/// to it as the mouse crosses the halfway point — the same feel as Messages.
///
/// Everything here is public API. A local event monitor sees the mouse-down;
/// `hitTest` says whether it landed on the split view itself, which is the divider, since
/// the columns are covered by their own views. The drag and the mouse-up are swallowed by
/// the split view's tracking loop and never reach a monitor, so the button's state comes
/// from `NSEvent.pressedMouseButtons` — the hardware — polled a few times a frame, and the
/// mouse position from the window, which knows it whether or not events are flowing.
///
/// Lives in the sidebar column's background, which is how it knows where the sidebar's
/// leading edge is: the background is the column's frame.
struct SidebarDividerTracker: View {
    @Binding var mode: SidebarMode

    @State private var leadingEdge: CGFloat = 0
    @State private var monitor: Any?
    @State private var tracking: Task<Void, Never>?

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minX
            } action: { edge in
                leadingEdge = edge
            }
            .onAppear(perform: install)
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window,
               window.contentView?.hitTest(event.locationInWindow) is NSSplitView {
                track(in: window)
            }
            return event
        }
    }

    private func remove() {
        tracking?.cancel()
        tracking = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Follows the mouse until the button comes up, choosing the width as it goes. The
    /// choice is made once more after the last poll, so a flick that is released between
    /// two polls still lands where it was let go.
    private func track(in window: NSWindow) {
        tracking?.cancel()
        tracking = Task { @MainActor in
            repeat {
                choose(forMouseAt: window.mouseLocationOutsideOfEventStream.x)
                try? await Task.sleep(for: .milliseconds(16))
            } while !Task.isCancelled && NSEvent.pressedMouseButtons & 1 != 0
            guard !Task.isCancelled else { return }
            choose(forMouseAt: window.mouseLocationOutsideOfEventStream.x)
        }
    }

    private func choose(forMouseAt x: CGFloat) {
        let wanted = SidebarMode.nearest(toWidth: x - leadingEdge)
        guard wanted != mode else { return }
        withAnimation(.smooth(duration: 0.2)) {
            mode = wanted
        }
    }
}
