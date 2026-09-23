import AppKit
import SwiftUI

/// A menu described once and built by AppKit at the moment it opens.
///
/// SwiftUI rebuilds a `Menu`'s contents whenever the view it sits in redraws — even while
/// the menu is open — and an open submenu blinks each time: the chat redraws on every
/// refresh, the call stage every second. An `NSMenu` made when it's clicked stays exactly as
/// it was until it closes, like every other menu on the Mac.
enum PopUpMenuItem {
    /// `isChecked` is nil for a plain action, and true or false for one that is on or off.
    /// `keys` only shows the shortcut beside the item; the shortcut itself is registered
    /// wherever the action lives.
    case action(
        String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        keys: KeyboardShortcut? = nil,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        perform: () -> Void
    )
    case submenu(String, systemImage: String? = nil, isEnabled: Bool = true, [PopUpMenuItem])
    /// A small grey heading over the items after it.
    case header(String)
    case divider

    @MainActor
    static func menu(_ items: [PopUpMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            switch entry {
            case let .action(title, systemImage, subtitle, keys, isChecked, isEnabled, perform):
                let item = ClosureMenuItem(title, symbol: systemImage, action: perform)
                item.subtitle = subtitle
                item.state = isChecked == true ? .on : .off
                item.isEnabled = isEnabled
                if let keys { item.show(keys) }
                menu.addItem(item)
            case let .submenu(title, systemImage, isEnabled, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                item.submenu = Self.menu(children)
                item.isEnabled = isEnabled
                menu.addItem(item)
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .divider:
                menu.addItem(.separator())
            }
        }
        // Dividers only between things: none leading, trailing or doubled up, whatever the
        // conditions above them left out.
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        for index in stride(from: menu.items.count - 1, to: 0, by: -1)
        where menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(at: index)
        }
        return menu
    }

    /// Opens the menu under `anchor`, as a pull-down menu opens under its button — or, with
    /// no anchor, under whatever was just clicked: a toolbar button, which SwiftUI draws
    /// without room for one.
    @MainActor
    static func show(_ items: [PopUpMenuItem], under anchor: NSView?) {
        let menu = menu(items)
        guard !menu.items.isEmpty else { return }
        if let anchor, anchor.window != nil {
            popUp(menu, under: anchor)
        } else if let event = NSApp.currentEvent, let window = event.window,
                  let clicked = window.contentView?.superview?.hitTest(event.locationInWindow) {
            popUp(menu, under: control(around: clicked))
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @MainActor
    private static func popUp(_ menu: NSMenu, under view: NSView) {
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }

    /// The button a click landed in, rather than the glyph inside it.
    @MainActor
    private static func control(around view: NSView) -> NSView {
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSControl { return candidate }
            current = candidate.superview
        }
        return view
    }
}

private extension NSMenuItem {
    /// The shortcut beside the item, as the menu bar prints it.
    func show(_ shortcut: KeyboardShortcut) {
        keyEquivalent = String(shortcut.key.character)
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        keyEquivalentModifierMask = mask
    }
}

/// A button that opens a ``PopUpMenuItem`` menu below itself, made when it's clicked.
struct PopUpMenuButton<Label: View>: View {
    var items: () -> [PopUpMenuItem]
    @ViewBuilder var label: () -> Label

    @State private var anchor = MenuAnchor.Box()

    var body: some View {
        Button {
            PopUpMenuItem.show(items(), under: anchor.view)
        } label: {
            label().background(MenuAnchor(box: anchor))
        }
    }
}

/// An empty view the size of the button's label, for the menu to open under.
struct MenuAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }

    /// Never in the way of a click.
    private final class PassThroughView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// A right-click menu built by AppKit at the click, in place of `.contextMenu` wherever
    /// the view redraws on its own — a SwiftUI context menu is rebuilt with it, and an open
    /// submenu blinks. `isOpen` is told when the menu opens and closes, for a view that draws
    /// its own outline while it's open.
    func popUpContextMenu(isOpen: ((Bool) -> Void)? = nil, _ items: @escaping () -> [PopUpMenuItem]) -> some View {
        overlay(ContextMenuHost(makeItems: items, setOpen: isOpen))
    }
}

/// Takes right clicks and control-clicks only; every other click goes through to the view
/// underneath.
private struct ContextMenuHost: NSViewRepresentable {
    let makeItems: () -> [PopUpMenuItem]
    let setOpen: ((Bool) -> Void)?

    func makeNSView(context: Context) -> HostView { HostView(frame: .zero) }

    func updateNSView(_ view: HostView, context: Context) {
        view.makeItems = makeItems
        view.setOpen = setOpen
    }

    final class HostView: NSView {
        var makeItems: (() -> [PopUpMenuItem])?
        var setOpen: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isContextClick(event) else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

        override func mouseDown(with event: NSEvent) {
            if Self.isContextClick(event) { showMenu(for: event) } else { super.mouseDown(with: event) }
        }

        private static func isContextClick(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        private func showMenu(for event: NSEvent) {
            guard let items = makeItems?() else { return }
            let menu = PopUpMenuItem.menu(items)
            guard !menu.items.isEmpty else { return }
            setOpen?(true)
            // Returns once the menu has closed.
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            setOpen?(false)
        }
    }
}
