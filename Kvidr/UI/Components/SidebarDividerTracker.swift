import AppKit
import SwiftUI

/// Turns a drag of the sidebar's divider into a choice between the two sidebar widths,
/// and a double-click on it into the other width.
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
/// the columns are covered by their own views. The mouse-down is swallowed there, so the
/// split view never begins a drag of its own; the button's state then comes from
/// `NSEvent.pressedMouseButtons` — the hardware — polled a few times a frame, and the
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
        SidebarItemPinner(mode: mode)
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved, .cursorUpdate]) { event in
            guard let window = event.window,
                  window.contentView?.hitTest(event.locationInWindow) is NSSplitView else { return event }
            switch event.type {
            case .leftMouseDown:
                // Swallowed: AppKit's own drag of the divider never starts, so nothing
                // can move the column but the choice below — the way Messages' divider
                // cannot be pulled past the narrow width at all. Left to AppKit, its
                // drag and our choice pulled the column two ways at once.
                if event.clickCount >= 2 {
                    // A double-click on the divider is the other way to the other
                    // width. The first click's tracking is still running and would
                    // only choose the width the mouse is already at; off with it.
                    tracking?.cancel()
                    tracking = nil
                    withAnimation(.smooth(duration: 0.2)) {
                        mode.toggle()
                    }
                } else {
                    track(in: window)
                }
                return nil
            case .cursorUpdate:
                // AppKit's own cursor for the divider says which way it could be dragged,
                // and it reads the pinned item as immovable. Swallowed, so ours stands.
                cursor.set()
                return nil
            default:
                cursor.set()
                return event
            }
        }
    }

    /// Over the divider: from the compact width the only way is wider, from the full width
    /// only narrower, and the cursor says so.
    private var cursor: NSCursor {
        mode == .compact ? .resizeRight : .resizeLeft
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

/// Keeps the sidebar's split view item from collapsing.
///
/// The column is pinned to one width, but a pinned item can still be dragged shut: below
/// its minimum AppKit collapses it, and with no sidebar toggle there is nothing to bring
/// it back. `canCollapse` is the item's own switch for that, and SwiftUI leaves it on.
/// Off, the divider simply stops at the column's edge. A collapse the inspector asks for
/// goes through `isCollapsed` directly and is unaffected.
///
/// Sits in the sidebar column's background, from where the split view is a walk up the
/// superview chain — once the view is actually under it, which is later than its first
/// move to a window. So the pin is tried at every step that could be the one, and again
/// at each change of width, in case SwiftUI has handed out a fresh item by then. It is
/// cheap: nothing happens once the item is off.
private struct SidebarItemPinner: NSViewRepresentable {
    /// Only here so that a change of width is an update.
    let mode: SidebarMode

    func makeNSView(context: Context) -> PinnerView { PinnerView() }
    func updateNSView(_ view: PinnerView, context: Context) { view.pin() }

    final class PinnerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pin()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            pin()
        }

        override func layout() {
            super.layout()
            pin()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func pin() {
            var view: NSView? = self
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let delegate = (view as? NSSplitView)?.delegate else { return }
            // SwiftUI's controller is an `NSSplitViewController` on macOS 26. Should it
            // stop being one, the items are still there for key-value coding.
            let items = (delegate as? NSSplitViewController)?.splitViewItems
                ?? ((delegate as? NSObject)?.responds(to: Selector(("splitViewItems"))) == true
                    ? (delegate as? NSObject)?.value(forKey: "splitViewItems") as? [NSSplitViewItem]
                    : nil)
            guard let sidebar = items?.first, sidebar.canCollapse else { return }
            sidebar.canCollapse = false
        }
    }
}
