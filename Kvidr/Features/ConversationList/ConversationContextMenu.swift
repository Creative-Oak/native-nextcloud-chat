import AppKit
import SwiftUI

/// The right-click menu on a conversation, wherever a conversation is drawn in the sidebar.
///
/// Described once, as entries, and drawn as an `NSMenu` made at the click — for the rows and
/// the favourite faces alike. Not SwiftUI's context menu: that is rebuilt with every redraw of
/// the sidebar, even while open, and its submenus blinked; and on the faces, which all sit in
/// one list row, it outlined the whole row rather than the face that was clicked.
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
            entries.append(.action(String(localized: "Join Call in Browser")) { model.openInBrowser(conversation) })
            entries.append(.divider)
        }

        entries.append(.action(conversation.isFavorite ? String(localized: "Remove from Favourites") : String(localized: "Add to Favourites")) {
            model.toggleFavorite(conversation)
        })
        if model.hasArchive {
            let title = conversation.isArchived
                ? String(localized: "Unarchive", comment: "Menu item: take the conversation out of the archive")
                : String(localized: "Archive", comment: "Menu item (verb): archive the conversation")
            entries.append(.action(title) {
                model.toggleArchived(conversation)
            })
        }
        if model.hasMarkUnread {
            entries.append(.action(String(localized: "Mark as Unread"), isEnabled: conversation.unreadMessages == 0) {
                model.markUnread(conversation)
            })
        }

        if model.hasTags, !conversation.isBreakoutRoom {
            var tags: [ConversationMenuEntry] = model.customTags.map { tag in
                .action(tag.name, isChecked: conversation.tagIDs.contains(tag.id)) {
                    model.setTag(tag, !conversation.tagIDs.contains(tag.id), for: conversation)
                }
            }
            if !tags.isEmpty { tags.append(.divider) }
            tags.append(.action(String(localized: "New Tag…", comment: "Menu item: make a new sidebar tag")) { model.beginNewTag(for: conversation) })
            entries.append(.submenu(String(localized: "Tags", comment: "Submenu: the conversation's sidebar tags"), tags))
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
                String(localized: "Important", comment: "Menu item: mark the conversation important"),
                subtitle: String(localized: "Notifies you even on Do Not Disturb"), isChecked: conversation.isImportant
            ) { model.toggleImportant(conversation) })
        }
        if model.hasSensitive {
            notifications.append(.action(
                String(localized: "Sensitive", comment: "Menu item: mark the conversation sensitive"),
                subtitle: String(localized: "Hides messages from the sidebar and notifications"), isChecked: conversation.isSensitive
            ) { model.toggleSensitive(conversation) })
        }
        entries.append(.submenu(String(localized: "Notifications"), notifications))

        entries.append(.divider)
        entries.append(.action(String(localized: "Copy Link")) { model.copyLink(to: conversation) })
        entries.append(.action(String(localized: "Open in Nextcloud")) { model.openInBrowser(conversation) })
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

/// A row's right-click menu, built by AppKit at the click. A SwiftUI context menu is rebuilt
/// with every redraw of the sidebar — and it redraws with each refresh — which made the Tags
/// and Notifications submenus blink while open. The list doesn't see the click, so the row
/// draws the outline the list would have.
struct ConversationRowMenu: ViewModifier {
    let model: ConversationListModel
    let token: String
    @Binding var menuToken: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if menuToken == token {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                ConversationMenuHost(
                    model: model,
                    token: token,
                    isOpen: Binding(get: { menuToken == token }, set: { menuToken = $0 ? token : nil })
                )
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
