import SwiftUI

/// The menu bar, rendered from the command registry — see `AppCommand`.
///
/// Every item is a real command with a real shortcut. Items that depend on a
/// capability the server doesn't have are disabled rather than hidden, so the menu's shape
/// stays stable and discoverable; with no window key, the registry's placeholder keeps
/// every item in its place, disabled.
struct TalkCommands: Commands {
    @FocusedValue(\.appCommands) private var registry

    var body: some Commands {
        // Replaces the default "New Window" — a second window on a messaging app is rarely
        // what anyone wants, and ⌘N should start a conversation.
        CommandGroup(replacing: .newItem) { items(.file) }
        CommandGroup(after: .newItem) { items(.refresh) }
        CommandGroup(replacing: .textEditing) { items(.find) }
        // Where Show/Hide Sidebar would be, had this app one.
        CommandGroup(after: .sidebar) { items(.sidebar) }
        CommandMenu("Conversation") { items(.conversation) }
        CommandGroup(replacing: .help) { items(.help) }
    }

    @ViewBuilder
    private func items(_ placement: AppCommand.Placement) -> some View {
        // Settings has its own menu item under the app menu; it is in the registry for
        // the palette, not for a second entry here.
        ForEach((registry ?? .placeholder).commands(in: placement).filter { $0.id != "app.settings" }) { command in
            Button(command.title, action: command.perform)
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isEnabled)
            if command.endsGroup {
                Divider()
            }
        }
    }
}
