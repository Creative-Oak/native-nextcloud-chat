import SwiftUI

/// The menu bar.
///
/// Every item here is a real command with a real shortcut. Items that depend on a
/// capability the server doesn't have are disabled rather than hidden, so the menu's shape
/// stays stable and discoverable.
struct TalkCommands: Commands {
    @FocusedValue(\.appModel) private var app
    @FocusedValue(\.composerFocusRequest) private var focusComposer
    @FocusedValue(\.searchFocusRequest) private var focusSearch

    var body: some Commands {
        // Replaces the default "New Window" — a second window on a messaging app is rarely
        // what anyone wants, and ⌘N should start a conversation.
        CommandGroup(replacing: .newItem) {
            Button("New Conversation…") { }
                .keyboardShortcut("n", modifiers: .command)
                // Phase 7: creating conversations. Disabled rather than absent, so the
                // shortcut doesn't silently do nothing somewhere else.
                .disabled(true)
        }

        CommandGroup(after: .newItem) {
            Button("Refresh Conversations") { app?.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app?.session == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") { focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(app?.session == nil)
        }

        CommandMenu("Conversation") {
            Button("Next Conversation") { app?.selectRelative(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Conversation") { app?.selectRelative(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Unread") { app?.selectNextUnread() }
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            Button("Focus Message Field") { focusComposer?() }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Button("Reply to Last Message") { app?.chat?.replyToLatest() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app?.chat == nil)

            Button("Edit Last Message") { app?.chat?.beginEditingLatestOwnMessage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(app?.chat?.capabilities.canEditMessages != true)

            Divider()

            Button("Mark as Unread") { app?.markSelectedUnread() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(app?.chat?.capabilities.canMarkUnread != true)

            Button(isSelectedFavorite ? "Remove from Favourites" : "Add to Favourites") {
                app?.toggleFavoriteOnSelection()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(app?.selectedToken == nil)

            Divider()

            Button("Open in Nextcloud") { app?.openSelectionInBrowser() }
                .disabled(app?.selectedToken == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Nextcloud Talk Documentation") {
                if let url = URL(string: "https://nextcloud-talk.readthedocs.io/en/latest/") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var isSelectedFavorite: Bool {
        guard let app, let token = app.selectedToken else { return false }
        return app.conversationList?[token]?.isFavorite ?? false
    }
}

// MARK: - Focused values
//
// The menu bar is outside the view hierarchy, so commands reach the current window's state
// through focused values rather than a global singleton.

private struct AppModelFocusedKey: FocusedValueKey { typealias Value = AppModel }
private struct ComposerFocusKey: FocusedValueKey { typealias Value = () -> Void }
private struct SearchFocusKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }

    var composerFocusRequest: (() -> Void)? {
        get { self[ComposerFocusKey.self] }
        set { self[ComposerFocusKey.self] = newValue }
    }

    var searchFocusRequest: (() -> Void)? {
        get { self[SearchFocusKey.self] }
        set { self[SearchFocusKey.self] = newValue }
    }
}
