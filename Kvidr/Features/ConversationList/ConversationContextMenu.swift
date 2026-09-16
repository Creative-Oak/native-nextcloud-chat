import AppKit
import SwiftUI

/// The right-click menu on a conversation, wherever a conversation is drawn in the sidebar.
///
/// Described once, as entries, and drawn two ways: as SwiftUI menu content for the rows,
/// where the list's own context menu is right, and as an `NSMenu` for the favourite faces.
/// The faces all sit in one list row, and a SwiftUI context menu there outlines the whole
/// row — every face — rather than the one that was clicked.
///
/// The entries read the conversation from the model by token when the menu opens rather
/// than trusting a copy captured with the row: a List row's menu can outlive the row's
/// value, and a stale copy offered "Sensitive" as off after it had been turned on.
enum ConversationMenuEntry {
    /// `isChecked` is nil for a plain action, and true or false for one that is on or off.
    case action(String, subtitle: String? = nil, isChecked: Bool? = nil, isEnabled: Bool = true, perform: () -> Void)
    case submenu(String, [ConversationMenuEntry])
    case divider

    @MainActor
    static func entries(model: ConversationListModel, token: String) -> [ConversationMenuEntry] {
        guard let conversation = model[token] else { return [] }
        var entries: [ConversationMenuEntry] = []

        if conversation.hasCall {
            entries.append(.action("Join Call in Browser") { model.openInBrowser(conversation) })
            entries.append(.divider)
        }

        entries.append(.action(conversation.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            model.toggleFavorite(conversation)
        })
        if model.hasArchive {
            entries.append(.action(conversation.isArchived ? "Unarchive" : "Archive") {
                model.toggleArchived(conversation)
            })
        }
        if model.hasMarkUnread {
            entries.append(.action("Mark as Unread", isEnabled: conversation.unreadMessages == 0) {
                model.markUnread(conversation)
            })
        }

        entries.append(.divider)

        var notifications: [ConversationMenuEntry] = Conversation.selectableNotificationLevels.map { level in
            .action(level.title, isChecked: conversation.effectiveNotificationLevel == level) {
                model.setNotificationLevel(level, for: conversation)
            }
        }
        if model.hasImportant || model.hasSensitive {
            notifications.append(.divider)
        }
        if model.hasImportant {
            notifications.append(.action(
                "Important", subtitle: "Notifies you even on Do Not Disturb", isChecked: conversation.isImportant
            ) { model.toggleImportant(conversation) })
        }
        if model.hasSensitive {
            notifications.append(.action(
                "Sensitive", subtitle: "Hides messages from the sidebar and notifications", isChecked: conversation.isSensitive
            ) { model.toggleSensitive(conversation) })
        }
        entries.append(.submenu("Notifications", notifications))

        entries.append(.divider)
        entries.append(.action("Copy Link") { model.copyLink(to: conversation) })
        entries.append(.action("Open in Nextcloud") { model.openInBrowser(conversation) })
        return entries
    }

    /// The same entries as an AppKit menu.
    @MainActor
    static func menu(_ entries: [ConversationMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .action(title, subtitle, isChecked, isEnabled, perform):
                let item = ClosureMenuItem(title, action: perform)
                item.subtitle = subtitle
                item.state = isChecked == true ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            case let .submenu(title, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = Self.menu(children)
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

/// The menu as SwiftUI content, for a row's `.contextMenu`.
struct ConversationContextMenu: View {
    let model: ConversationListModel
    let token: String

    init(model: ConversationListModel, conversation: Conversation) {
        self.model = model
        self.token = conversation.token
    }

    var body: some View {
        ConversationMenuEntriesView(entries: ConversationMenuEntry.entries(model: model, token: token))
    }
}

/// A nominal view, so a submenu can draw its entries with the same view.
private struct ConversationMenuEntriesView: View {
    let entries: [ConversationMenuEntry]

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            switch entries[index] {
            case let .action(title, subtitle, isChecked, isEnabled, perform):
                // A checkable entry is a Toggle, which a menu draws with the system's
                // checkmark. A checkmark *icon* on a Button is not shown: macOS 26 leaves
                // images out of these menus.
                if let isChecked {
                    Toggle(isOn: Binding(get: { isChecked }, set: { _ in perform() })) {
                        Text(title)
                        if let subtitle { Text(subtitle) }
                    }
                    .disabled(!isEnabled)
                } else {
                    Button(action: perform) {
                        Text(title)
                        if let subtitle { Text(subtitle) }
                    }
                    .disabled(!isEnabled)
                }
            case let .submenu(title, children):
                Menu(title) { ConversationMenuEntriesView(entries: children) }
            case .divider:
                Divider()
            }
        }
    }
}

/// Opens the conversation menu from a view of its own on a right click or a control-click,
/// so the list underneath never sees the click and draws no outline around its row. Hit-test
/// transparent for every other click, so a plain click still goes to the face's button.
struct ConversationMenuHost: NSViewRepresentable {
    let model: ConversationListModel
    let token: String
    /// True while the menu is open, for the view to draw its own outline.
    @Binding var isOpen: Bool

    func makeNSView(context: Context) -> RightClickView { RightClickView(frame: .zero) }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.makeMenu = { ConversationMenuEntry.menu(ConversationMenuEntry.entries(model: model, token: token)) }
        view.setOpen = { isOpen = $0 }
    }

    final class RightClickView: NSView {
        var makeMenu: (() -> NSMenu)?
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
            guard let menu = makeMenu?() else { return }
            setOpen?(true)
            // Returns once the menu has closed.
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            setOpen?(false)
        }
    }
}
