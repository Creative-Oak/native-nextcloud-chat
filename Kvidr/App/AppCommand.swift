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
        case .space: text += String(localized: "Space", comment: "The space bar's name in a keyboard shortcut, as macOS menus print it (⌃⌘Space)")
        default: text += String(shortcut.key.character).uppercased()
        }
        return text
    }

    /// The English aliases, which every language keeps, and the user's language's own
    /// from one comma-separated catalog string.
    static func words(_ english: [String], _ localized: String) -> [String] {
        let own = localized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return english + own.filter { !english.contains($0) }
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
        var ask: () -> Void = {}
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
        let noSession = String(localized: "Sign in first", comment: "Command palette: why a command is disabled")
        let noChat = String(localized: "Open a conversation first", comment: "Command palette: why a command is disabled")
        let noSelection = String(localized: "Select a conversation first", comment: "Command palette: why a command is disabled")
        let inCall = String(localized: "Minimize the call first", comment: "Command palette: why a command is disabled while a call fills the window")
        let noAppleIntelligence = String(localized: "Apple Intelligence isn’t available on this Mac", comment: "Command palette: why a command is disabled")
        // Somewhere to go: signed in, and no call filling the window.
        let roam = session && !c.isCallFullScreen
        let roamReason = c.isCallFullScreen ? inCall : noSession

        let commands: [AppCommand] = [
            AppCommand(
                id: "conversation.new", title: String(localized: "New Message"), aliases: AppCommand.words(["start", "create", "group", "new conversation", "message someone"], String(localized: "start, create, group, new conversation, message someone", comment: "Command palette search words for New Message, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "square.and.pencil", shortcut: KeyboardShortcut("n", modifiers: .command), placement: .file,
                isEnabled: live && c.canCreateConversations && !c.isCallFullScreen,
                disabledReason: c.isCallFullScreen ? inCall : c.hasSession ? String(localized: "This server does not let you start conversations") : noSession,
                perform: c.newConversation
            ),
            AppCommand(
                id: "conversations.refresh", title: String(localized: "Refresh Conversations"), aliases: AppCommand.words(["reload", "sync", "update"], String(localized: "reload, sync, update", comment: "Command palette search words for Refresh Conversations, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "arrow.clockwise", shortcut: KeyboardShortcut("r", modifiers: .command), placement: .refresh,
                isEnabled: session, disabledReason: noSession, perform: c.refresh
            ),
            AppCommand(
                id: "conversations.find", title: String(localized: "Find Conversation…"), aliases: AppCommand.words(["filter", "sidebar search"], String(localized: "filter, sidebar search", comment: "Command palette search words for Find Conversation (filters the sidebar), comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: .command), placement: .find,
                isEnabled: roam, disabledReason: roamReason, perform: c.findConversation
            ),
            AppCommand(
                id: "chat.find", title: String(localized: "Find in Conversation…"), aliases: AppCommand.words(["search here", "find text"], String(localized: "search here, find text", comment: "Command palette search words for Find in Conversation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "text.magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: [.command, .option]), placement: .find,
                isEnabled: chat, disabledReason: noChat, perform: c.findInConversation
            ),
            // Distinct from Find in Conversation: that one searches what is loaded and
            // answers instantly; this one asks the server and can reach anything.
            AppCommand(
                id: "messages.search", title: String(localized: "Search Messages…"), aliases: AppCommand.words(["server search", "history", "find message"], String(localized: "server search, history, find message", comment: "Command palette search words for Search Messages (on the server), comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "doc.text.magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]), placement: .find,
                isEnabled: roam, disabledReason: roamReason, perform: c.searchMessages
            ),
            // Where Show/Hide Sidebar would be, had this app one: the sidebar does not
            // hide, it folds down to a column of faces.
            AppCommand(
                id: "sidebar.toggle", title: c.isSidebarCompact ? String(localized: "Use Full Sidebar") : String(localized: "Use Compact Sidebar", comment: "Menu item: fold the sidebar down to a narrow column of avatars"),
                aliases: AppCommand.words(["sidebar", "compact", "narrow", "wide", "faces", "column"], String(localized: "sidebar, compact, narrow, wide, faces, column", comment: "Command palette search words for switching between the full and the compact (avatars only) sidebar, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "sidebar.left", shortcut: KeyboardShortcut("s", modifiers: [.command, .control]), placement: .sidebar,
                isEnabled: session, disabledReason: noSession, perform: c.toggleSidebar
            ),
            AppCommand(
                id: "conversation.next", title: String(localized: "Next Conversation"), aliases: AppCommand.words(["down"], String(localized: "down", comment: "Command palette search words for Next Conversation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "arrow.down", shortcut: KeyboardShortcut(.downArrow, modifiers: [.command, .option]), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, perform: c.nextConversation
            ),
            AppCommand(
                id: "conversation.previous", title: String(localized: "Previous Conversation"), aliases: AppCommand.words(["up"], String(localized: "up", comment: "Command palette search words for Previous Conversation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "arrow.up", shortcut: KeyboardShortcut(.upArrow, modifiers: [.command, .option]), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, perform: c.previousConversation
            ),
            AppCommand(
                id: "conversation.nextUnread", title: String(localized: "Next Unread", comment: "Menu item: go to the next conversation with unread messages"), aliases: AppCommand.words(["unread", "jump"], String(localized: "unread, jump", comment: "Command palette search words for Next Unread, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "circle.fill", shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]), placement: .conversation,
                endsGroup: true, isEnabled: roam, disabledReason: roamReason, perform: c.nextUnread
            ),
            AppCommand(
                id: "palette", title: String(localized: "Go to Anything…"), aliases: ["palette", "spotlight", "search"],
                symbolName: "command", shortcut: KeyboardShortcut("p", modifiers: .command), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, isHiddenFromPalette: true, perform: c.openPalette
            ),
            // The same palette under the shortcut it had as a switcher, so the fingers
            // that learned ⌘K keep working.
            AppCommand(
                id: "palette.conversation", title: String(localized: "Go to Conversation…"), aliases: [],
                symbolName: "command", shortcut: KeyboardShortcut("k", modifiers: .command), placement: .conversation,
                isEnabled: roam, disabledReason: roamReason, isHiddenFromPalette: true, perform: c.openPalette
            ),
            AppCommand(
                id: "composer.focus", title: String(localized: "Focus Message Field"), aliases: AppCommand.words(["type", "compose", "write"], String(localized: "type, compose, write", comment: "Command palette search words for Focus Message Field, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "text.cursor", shortcut: KeyboardShortcut("k", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.focusComposer
            ),
            AppCommand(
                id: "chat.replyToLatest", title: String(localized: "Reply to Last Message"), aliases: AppCommand.words(["reply", "quote"], String(localized: "reply, quote", comment: "Command palette search words for Reply to Last Message, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "arrowshape.turn.up.left", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.replyToLatest
            ),
            AppCommand(
                id: "chat.editLatest", title: String(localized: "Edit Last Message"), aliases: AppCommand.words(["edit", "fix", "correct"], String(localized: "edit, fix, correct", comment: "Command palette search words for Edit Last Message, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "pencil", shortcut: KeyboardShortcut(.upArrow, modifiers: .command), placement: .conversation,
                endsGroup: true, isEnabled: chat && c.canEditMessages,
                disabledReason: c.hasChat ? String(localized: "This server does not let you edit messages") : noChat, perform: c.editLatest
            ),
            AppCommand(
                id: "conversation.summarize", title: String(localized: "Summarize Conversation"), aliases: AppCommand.words(["summary", "catch up", "tl;dr", "apple intelligence"], String(localized: "summary, catch up, tl;dr, apple intelligence", comment: "Command palette search words for Summarize Conversation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "apple.intelligence", shortcut: KeyboardShortcut("s", modifiers: [.command, .option]), placement: .conversation,
                isEnabled: chat && c.canSummarize,
                disabledReason: c.hasChat ? noAppleIntelligence : noChat, perform: c.summarize
            ),
            AppCommand(
                id: "conversation.ask", title: String(localized: "Ask This Conversation…", comment: "Menu item: ask Apple Intelligence a question about the open conversation"), aliases: AppCommand.words(["ask", "question", "find out", "apple intelligence"], String(localized: "ask, question, find out, apple intelligence", comment: "Command palette search words for Ask This Conversation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "questionmark.bubble", shortcut: KeyboardShortcut("a", modifiers: [.command, .option]), placement: .conversation,
                isEnabled: chat && c.canSummarize,
                disabledReason: c.hasChat ? noAppleIntelligence : noChat, perform: c.ask
            ),
            AppCommand(
                id: "conversation.markUnread", title: String(localized: "Mark as Unread"), aliases: AppCommand.words(["unread", "later"], String(localized: "unread, later", comment: "Command palette search words for Mark as Unread, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "envelope.badge", shortcut: KeyboardShortcut("u", modifiers: [.command, .shift]), placement: .conversation,
                isEnabled: chat && c.canMarkUnread,
                disabledReason: c.hasChat ? String(localized: "This server does not let you mark conversations unread") : noChat, perform: c.markUnread
            ),
            AppCommand(
                id: "conversation.favorite", title: c.isSelectionFavorite ? String(localized: "Remove from Favourites") : String(localized: "Add to Favourites"),
                aliases: AppCommand.words(["favourite", "favorite", "star", "pin"], String(localized: "favourite, favorite, star, pin", comment: "Command palette search words for Add to / Remove from Favourites, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: c.isSelectionFavorite ? "star.slash" : "star", shortcut: KeyboardShortcut("d", modifiers: [.command, .shift]),
                placement: .conversation, isEnabled: selection, disabledReason: noSelection, perform: c.toggleFavorite
            ),
            AppCommand(
                id: "conversation.archive", title: c.isSelectionArchived
                    ? String(localized: "Unarchive", comment: "Menu item: take the selected conversation out of the archive")
                    : String(localized: "Archive", comment: "Menu item (verb): archive the selected conversation"),
                aliases: AppCommand.words(["archive", "unarchive", "hide", "file away"], String(localized: "archive, unarchive, hide, file away", comment: "Command palette search words for Archive / Unarchive, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: c.isSelectionArchived ? "archivebox.fill" : "archivebox", placement: .conversation,
                endsGroup: true, isEnabled: selection && c.canArchive,
                disabledReason: c.hasSelection ? String(localized: "This server does not archive conversations") : noSelection, perform: c.toggleArchive
            ),
            AppCommand(
                id: "conversation.details", title: String(localized: "Show Conversation Details"), aliases: AppCommand.words(["inspector", "info", "people", "files", "settings"], String(localized: "inspector, info, people, files, settings", comment: "Command palette search words for Show Conversation Details, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "info.circle", shortcut: KeyboardShortcut("i", modifiers: [.command, .option]), placement: .conversation,
                isEnabled: chat, disabledReason: noChat, perform: c.toggleInspector
            ),
            AppCommand(
                id: "conversation.openInBrowser", title: String(localized: "Open in Nextcloud", comment: "Menu item: open the selected conversation in Nextcloud in the web browser"), aliases: AppCommand.words(["browser", "web", "safari"], String(localized: "browser, web, safari", comment: "Command palette search words for Open in Nextcloud (the web browser), comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "safari", placement: .conversation,
                isEnabled: selection, disabledReason: noSelection, perform: c.openInBrowser
            ),
            AppCommand(
                id: "help.shortcuts", title: String(localized: "Keyboard Shortcuts"), aliases: AppCommand.words(["keys", "hotkeys", "help"], String(localized: "keys, hotkeys, help", comment: "Command palette search words for Keyboard Shortcuts, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "keyboard", shortcut: KeyboardShortcut("/", modifiers: .command), placement: .help,
                endsGroup: true, isEnabled: live, perform: c.showKeyboardShortcuts
            ),
            AppCommand(
                id: "help.documentation", title: String(localized: "Nextcloud Talk Documentation"), aliases: AppCommand.words(["docs", "manual", "help"], String(localized: "docs, manual, help", comment: "Command palette search words for Nextcloud Talk Documentation, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
                symbolName: "book", placement: .help, isEnabled: live, perform: c.openDocumentation
            ),
            // ⌘, is the app menu's own item; this is the palette's way there, and it is
            // kept out of the other menus.
            AppCommand(
                id: "app.settings", title: String(localized: "Settings…"), aliases: AppCommand.words(["preferences", "options", "notifications", "account"], String(localized: "preferences, options, notifications, account", comment: "Command palette search words for Settings, comma-separated, found alongside the English ones. Use your own language's words; the list need not match the English.")),
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
