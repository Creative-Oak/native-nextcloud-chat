import SwiftUI

/// Help → Keyboard Shortcuts.
///
/// The app is meant to be usable without the mouse, which only works if the shortcuts are
/// discoverable. The menu bar carries most of them; this is the one page that shows them
/// all together, including the ones that live in the composer rather than in a menu.
struct KeyboardShortcutsWindow: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(group.shortcuts) { shortcut in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(shortcut.description)
                                    Spacer(minLength: 24)
                                    Text(shortcut.keys)
                                        .font(.system(.callout, design: .rounded).weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 560)
    }

    /// Structs rather than tuples: Swift has no key paths into tuple elements, which
    /// `ForEach(_:id:)` needs.
    private struct ShortcutGroup: Identifiable {
        var id: String { title }
        let title: String
        let shortcuts: [Shortcut]
    }

    private struct Shortcut: Identifiable {
        var id: String { keys + description }
        let description: String
        let keys: String
    }

    private static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Getting around", shortcuts: [
            Shortcut(description: "Go to conversation", keys: "⌘K"),
            Shortcut(description: "Find a conversation", keys: "⌘F"),
            Shortcut(description: "Search messages on the server", keys: "⇧⌘F"),
            Shortcut(description: "Next / previous conversation", keys: "⌥⌘↓ ⌥⌘↑"),
            Shortcut(description: "Next unread conversation", keys: "⇧⌘]"),
            Shortcut(description: "Show conversation details", keys: "⌥⌘I"),
            Shortcut(description: "Compact / full sidebar", keys: "⌃⌘S"),
            Shortcut(description: "Refresh conversations", keys: "⌘R")
        ]),
        ShortcutGroup(title: "In a conversation", shortcuts: [
            Shortcut(description: "Find in conversation", keys: "⌥⌘F"),
            Shortcut(description: "Next / previous match", keys: "⌘G ⇧⌘G"),
            Shortcut(description: "Focus the message field", keys: "⇧⌘K"),
            Shortcut(description: "Reply to the newest message", keys: "⇧⌘R"),
            Shortcut(description: "Edit your last message", keys: "⌘↑"),
            Shortcut(description: "Mark as unread", keys: "⇧⌘U"),
            Shortcut(description: "Favourite / unfavourite", keys: "⇧⌘D")
        ]),
        ShortcutGroup(title: "Writing", shortcuts: [
            Shortcut(description: "Send", keys: "Return"),
            Shortcut(description: "New line", keys: "⇧Return"),
            Shortcut(description: "Send (always)", keys: "⌘Return"),
            Shortcut(description: "Cancel a reply or edit", keys: "Escape"),
            Shortcut(description: "Mention someone", keys: "@"),
            Shortcut(description: "Choose a mention", keys: "↑ ↓ then Return or Tab"),
            Shortcut(description: "Attach a file", keys: "⇧⌘A"),
            Shortcut(description: "Emoji & Symbols", keys: "⌃⌘Space")
        ]),
        ShortcutGroup(title: "App", shortcuts: [
            Shortcut(description: "New conversation", keys: "⌘N"),
            Shortcut(description: "Settings", keys: "⌘,"),
            Shortcut(description: "Close window", keys: "⌘W"),
            Shortcut(description: "Minimise", keys: "⌘M"),
            Shortcut(description: "Hide", keys: "⌘H"),
            Shortcut(description: "Quit", keys: "⌘Q")
        ])
    ]
}
