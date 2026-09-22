import AppKit
import SwiftUI

/// One thing the app can do on request: a menu item, a shortcut, and a row in the
/// command palette, all from this one description. The menu bar and the palette both
/// render the registry, so a command can be in one and not the other only on purpose.
struct AppCommand: Identifiable {
    /// Where the menu bar puts it. The palette lists them all regardless.
    enum Placement: Hashable, CaseIterable {
        /// File, replacing New Window: ⌘N starts a conversation.
        case file
        /// After that.
        case refresh
        /// Edit, in place of the text-editing find items.
        case find
        /// View, where Show/Hide Sidebar would be.
        case sidebar
        /// The Conversation menu.
        case conversation
        /// Help.
        case help
    }

    let id: String
    let title: String
    /// Other words the palette should find it by.
    var aliases: [String] = []
    var symbolName: String
    var shortcut: KeyboardShortcut?
    let placement: Placement
    /// A divider follows this item in its menu.
    var endsGroup = false
    var isEnabled = true
    /// Why it is disabled, for the palette's row.
    var disabledReason: String?
    /// The palette's own commands are not offered from inside it.
    var isHiddenFromPalette = false
    let perform: () -> Void

    /// The shortcut as the menu bar prints it: "⇧⌘F".
    var keys: String? { shortcut.map(Self.describe) }

    static func describe(_ shortcut: KeyboardShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        switch shortcut.key {
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .return: text += "↩"
        case .escape: text += "⎋"
        case .space: text += "Space"
        default: text += String(shortcut.key.character).uppercased()
        }
        return text
    }
}

/// Everything the window can do right now, in menu order.
struct AppCommandRegistry {
    var commands: [AppCommand]

    func commands(in placement: AppCommand.Placement) -> [AppCommand] {
        commands.filter { $0.placement == placement }
    }

    var paletteCommands: [AppCommand] {
        commands.filter { !$0.isHiddenFromPalette }
    }

    /// What the palette offers before anything is typed.
    var suggested: [AppCommand] {
        let ids = ["conversation.new", "messages.search", "sidebar.toggle", "conversations.refresh", "conversation.details", "help.shortcuts"]
        return ids.compactMap { id in commands.first { $0.id == id } }
    }

    /// The state and the handlers a registry is built from. `nil` — no window is key —
    /// gives the same commands, all disabled, so the menu's shape never changes.
    struct Context {
        var hasSession = false
        var hasChat = false
        var hasSelection = false
        var canCreateConversations = false
        var canEditMessages = false
        var canMarkUnread = false
        var isSidebarCompact = false
        var isSelectionFavorite = false
        var isSelectionArchived = false
        var canArchive = false
        var canSummarize = false
        /// A call has the window: moving elsewhere waits until it is minimized.
        var isCallFullScreen = false

        var newConversation: () -> Void = {}
        var refresh: () -> Void = {}
        var findConversation: () -> Void = {}
        var findInConversation: () -> Void = {}
        var searchMessages: () -> Void = {}
        var toggleSidebar: () -> Void = {}
        var nextConversation: () -> Void = {}
        var previousConversation: () -> Void = {}
        var nextUnread: () -> Void = {}
        var openPalette: () -> Void = {}
        var focusComposer: () -> Void = {}
        var replyToLatest: () -> Void = {}
        var editLatest: () -> Void = {}
        var markUnread: () -> Void = {}
        var summarize: () -> Void = {}
        var toggleFavorite: () -> Void = {}
        var toggleArchive: () -> Void = {}
        var toggleInspector: () -> Void = {}
        var openInBrowser: () -> Void = {}
        var showKeyboardShortcuts: () -> Void = {}
        var openDocumentation: () -> Void = {}
        var openSettings: () -> Void = {}
    }

    /// No window: every command in its place, none of them live. Computed — the
    /// commands hold closures, which are not `Sendable`, so a stored global is not
    /// allowed; and building the twenty of them is nothing.
    static var placeholder: AppCommandRegistry { make(Context(), isLive: false) }

    static func make(_ c: Context, isLive: Bool = true) -> AppCommandRegistry {
        let live = isLive
        let session = live && c.hasSession
        let chat = live && c.hasChat
        let selection = live && c.hasSelection
        let noSession = "Sign in first"
        let noChat = "Open a conversation first"
        let noSelection = "Select a conversation first"
        let inCall = "Minimize the call first"
        // Somewhere to go: signed in, and no call filling the window.
        let roam = session && !c.isCallFullScreen
        let roamReason = c.isCallFullScreen ? inCall : noSession

        let commands: [AppCommand] = [
            AppCommand(
                id: "conversation.new", title: "New Message", aliases: ["start", "create", "group", "new conversation", "message someone"],
                symbolName: "square.and.pencil", shortcut: KeyboardShortcut("n", modifiers: .command), placement: .file,
                isEnabled: live && c.canCreateConversations && !c.isCallFullScreen,
                disabledReason: c.isCallFullScreen ? inCall : c.hasSession ? "This server does not let you start conversations" : noSession,
                perform: c.newConversation
            ),
            AppCommand(
                id: "conversations.refresh", title: "Refresh Conversations", aliases: ["reload", "sync", "update"],
                symbolName: "arrow.clockwise", shortcut: KeyboardShortcut("r", modifiers: .command), placement: .refresh,
                isEnabled: session, disabledReason: noSession, perform: c.refresh
            ),
            AppCommand(
                id: "conversations.find", title: "Find Conversation…", aliases: ["filter", "sidebar search"],
                symbolName: "magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: .command), placement: .find,
                isEnabled: roam, disabledReason: roamReason, perform: c.findConversation
            ),
            AppCommand(
                id: "chat.find", title: "Find in Conversation…", aliases: ["search here", "find text"],
                symbolName: "text.magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: [.command, .option]), placement: .find,
                isEnabled: chat, disabledReason: noChat, perform: c.findInConversation
            ),
            // Distinct from Find in Conversation: that one searches what is loaded and
            // answers instantly; this one asks the server and can reach anything.
            AppCommand(
                id: "messages.search", title: "Search Messages…", aliases: ["server search", "history", "find message"],
                symbolName: "doc.text.magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]), placement: .find,
                isEnabled: roam, disabledReason: roamReason, perform: c.searchMessages
            ),
            // Where Show/Hide Sidebar would be, had this app one: the sidebar does not
            // hide, it folds down to a column of faces.
            AppCommand(
                id: "sidebar.toggle", title: c.isSidebarCompact ? "Use Full Sidebar" : "Use Compact Sidebar",
                aliases: ["sidebar", "compact", "narrow", "wide", "faces", "column"],
                symbolName: "sidebar.left", shortcut: KeyboardShortcut("s", modifiers: [.command, .control]), placement: .sidebar,
                isEnabled: session, disabledReason: noSession, perform: c.toggleSidebar
            ),
            AppCommand(
                id: "conversation.next", title: "Next Conversation", aliases: ["down"],
                symbolName: "arrow.down", shortcut: KeyboardShortcut(.downArrow, modifiers: [.command, .option]), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, perform: c.nextConversation
            ),
            AppCommand(
                id: "conversation.previous", title: "Previous Conversation", aliases: ["up"],
                symbolName: "arrow.up", shortcut: KeyboardShortcut(.upArrow, modifiers: [.command, .option]), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, perform: c.previousConversation
            ),
            AppCommand(
                id: "conversation.nextUnread", title: "Next Unread", aliases: ["unread", "jump"],
                symbolName: "circle.fill", shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]), placement: .conversation,
                endsGroup: true, isEnabled: roam, disabledReason: roamReason, perform: c.nextUnread
            ),
            AppCommand(
                id: "palette", title: "Go to Anything…", aliases: ["palette", "spotlight", "search"],
                symbolName: "command", shortcut: KeyboardShortcut("p", modifiers: .command), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, isHiddenFromPalette: true, perform: c.openPalette
            ),
            // The same palette under the shortcut it had as a switcher, so the fingers
            // that learned ⌘K keep working.
            AppCommand(
                id: "palette.conversation", title: "Go to Conversation…", aliases: [],
                symbolName: "command", shortcut: KeyboardShortcut("k", modifiers: .command), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, isHiddenFromPalette: true, perform: c.openPalette
            ),
            AppCommand(
                id: "composer.focus", title: "Focus Message Field", aliases: ["type", "compose", "write"],
                symbolName: "text.cursor", shortcut: KeyboardShortcut("k", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.focusComposer
            ),
            AppCommand(
                id: "chat.replyToLatest", title: "Reply to Last Message", aliases: ["reply", "quote"],
                symbolName: "arrowshape.turn.up.left", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.replyToLatest
            ),
            AppCommand(
                id: "chat.editLatest", title: "Edit Last Message", aliases: ["edit", "fix", "correct"],
                symbolName: "pencil", shortcut: KeyboardShortcut(.upArrow, modifiers: .command), placement: .conversation,
                endsGroup: true, isEnabled: chat && c.canEditMessages,
                disabledReason: c.hasChat ? "This server does not let you edit messages" : noChat, perform: c.editLatest
            ),
            AppCommand(
                id: "conversation.summarize", title: "Summarize Conversation", aliases: ["summary", "catch up", "tl;dr", "apple intelligence"],
                symbolName: "apple.intelligence", shortcut: KeyboardShortcut("s", modifiers: [.command, .option]), placement: .conversation,
                isEnabled: chat && c.canSummarize,
                disabledReason: c.hasChat ? "Apple Intelligence isn’t available on this Mac" : noChat, perform: c.summarize
            ),
            AppCommand(
                id: "conversation.markUnread", title: "Mark as Unread", aliases: ["unread", "later"],
                symbolName: "envelope.badge", shortcut: KeyboardShortcut("u", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat && c.canMarkUnread,
                disabledReason: c.hasChat ? "This server does not let you mark conversations unread" : noChat, perform: c.markUnread
            ),
            AppCommand(
                id: "conversation.favorite", title: c.isSelectionFavorite ? "Remove from Favourites" : "Add to Favourites",
                aliases: ["favourite", "favorite", "star", "pin"],
                symbolName: c.isSelectionFavorite ? "star.slash" : "star", shortcut: KeyboardShortcut("d", modifiers: [.command, .shift]),
                placement: .conversation, isEnabled: selection, disabledReason: noSelection, perform: c.toggleFavorite
            ),
            AppCommand(
                id: "conversation.archive", title: c.isSelectionArchived ? "Unarchive" : "Archive",
                aliases: ["archive", "unarchive", "hide", "file away"],
                symbolName: c.isSelectionArchived ? "archivebox.fill" : "archivebox", placement: .conversation,
                endsGroup: true, isEnabled: selection && c.canArchive,
                disabledReason: c.hasSelection ? "This server does not archive conversations" : noSelection, perform: c.toggleArchive
            ),
            AppCommand(
                id: "conversation.details", title: "Show Conversation Details", aliases: ["inspector", "info", "people", "files", "settings"],
                symbolName: "info.circle", shortcut: KeyboardShortcut("i", modifiers: [.command, .option]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.toggleInspector
            ),
            AppCommand(
                id: "conversation.openInBrowser", title: "Open in Nextcloud", aliases: ["browser", "web", "safari"],
                symbolName: "safari", placement: .conversation,
                isEnabled: selection, disabledReason: noSelection, perform: c.openInBrowser
            ),
            AppCommand(
                id: "help.shortcuts", title: "Keyboard Shortcuts", aliases: ["keys", "hotkeys", "help"],
                symbolName: "keyboard", shortcut: KeyboardShortcut("/", modifiers: .command), placement: .help,
                endsGroup: true, isEnabled: live, perform: c.showKeyboardShortcuts
            ),
            AppCommand(
                id: "help.documentation", title: "Nextcloud Talk Documentation", aliases: ["docs", "manual", "help"],
                symbolName: "book", placement: .help, isEnabled: live, perform: c.openDocumentation
            ),
            // ⌘, is the app menu's own item; this is the palette's way there, and it is
            // kept out of the other menus.
            AppCommand(
                id: "app.settings", title: "Settings…", aliases: ["preferences", "options", "notifications", "account"],
                symbolName: "gearshape", shortcut: KeyboardShortcut(",", modifiers: .command), placement: .help,
                isEnabled: live, perform: c.openSettings
            )
        ]
        assert(Set(commands.map(\.id)).count == commands.count, "command ids must be unique")
        return AppCommandRegistry(commands: commands)
    }
}

// MARK: - Focused value
//
// The menu bar is outside the view hierarchy, so commands reach the current window's
// state through a focused value rather than a global singleton.

private struct AppCommandsKey: FocusedValueKey { typealias Value = AppCommandRegistry }

extension FocusedValues {
    var appCommands: AppCommandRegistry? {
        get { self[AppCommandsKey.self] }
        set { self[AppCommandsKey.self] = newValue }
    }
}
