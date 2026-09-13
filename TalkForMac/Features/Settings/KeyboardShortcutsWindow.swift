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
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(group.shortcuts, id: \.keys) { shortcut in
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

    private struct Group {
        let title: String
        let shortcuts: [(description: String, keys: String)]
    }

    private static let groups: [Group] = [
        Group(title: "Getting around", shortcuts: [
            ("Go to conversation", "⌘K"),
            ("Find a conversation", "⌘F"),
            ("Next / previous conversation", "⌥⌘↓ ⌥⌘↑"),
            ("Next unread conversation", "⇧⌘]"),
            ("Show conversation details", "⌥⌘I"),
            ("Refresh conversations", "⌘R")
        ]),
        Group(title: "In a conversation", shortcuts: [
            ("Find in conversation", "⌥⌘F"),
            ("Next / previous match", "⌘G ⇧⌘G"),
            ("Focus the message field", "⇧⌘K"),
            ("Reply to the newest message", "⇧⌘R"),
            ("Edit your last message", "⌘↑"),
            ("Mark as unread", "⇧⌘U"),
            ("Favourite / unfavourite", "⇧⌘D")
        ]),
        Group(title: "Writing", shortcuts: [
            ("Send", "Return"),
            ("New line", "⇧Return"),
            ("Send (always)", "⌘Return"),
            ("Cancel a reply or edit", "Escape"),
            ("Mention someone", "@"),
            ("Choose a mention", "↑ ↓ then Return or Tab"),
            ("Attach a file", "⇧⌘A"),
            ("Emoji & Symbols", "⌃⌘Space")
        ]),
        Group(title: "App", shortcuts: [
            ("New conversation", "⌘N"),
            ("Settings", "⌘,"),
            ("Close window", "⌘W"),
            ("Minimise", "⌘M"),
            ("Hide", "⌘H"),
            ("Quit", "⌘Q")
        ])
    ]
}
