import SwiftUI

/// What stands in the sidebar column: the full list, the compact one, or — for the frame
/// or two before the cache has opened — a stand-in with the column's width and nothing in
/// it. The stand-in matters: a column whose content is an `EmptyView` is sized from that
/// emptiness, and AppKit keeps the width once the list arrives.
struct SidebarColumn: View {
    let list: ConversationListModel?
    let mode: SidebarMode
    @Binding var selection: String?
    @Binding var composerFocused: Bool
    var searchFocusRequest: Bool
    var onSearchFocusHandled: () -> Void
    /// The unsent conversation, which sits above the real ones.
    var draft: ConversationDraft?
    var onDiscardDraft: () -> Void
    var profile: ProfileModel?
    var reminderCount = 0
    var onOpenSettings: () -> Void = {}
    /// iOS: the list is a screen of its own, so it carries what the Mac keeps in the toolbar
    /// and the menu bar.
    var onNewMessage: () -> Void = {}
    var onGoToAnything: () -> Void = {}
    var onSearchMessages: () -> Void = {}
    var onOpenReminders: () -> Void = {}

    var body: some View {
        #if os(macOS)
        lists
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let profile {
                    SidebarAccountRow(
                        profile: profile,
                        mode: mode,
                        isSelected: SettingsToken.isSettings(selection),
                        onOpen: onOpenSettings
                    )
                }
            }
        #else
        // Messages' list screen: a centred title between two glass buttons, and the search
        // field and compose button floating at the foot of the screen.
        lists
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: searchText, prompt: "Search")
            .toolbar {
                if let profile {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onOpenSettings) {
                            ProfileAvatar(profile: profile, size: 44, showsStatus: true)
                        }
                        // The toolbar keeps a glass button's padding around an item even with
                        // the glass hidden; without it, the picture's edge is on the list's
                        // 16pt margin, as the button on the right is.
                        .padding(.leading, -14)
                        .accessibilityLabel("Settings")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Go to Anything", systemImage: "magnifyingglass", action: onGoToAnything)
                        Button("Search Messages", systemImage: "text.magnifyingglass", action: onSearchMessages)
                        if reminderCount > 0 {
                            Button("Reminders (\(reminderCount))", systemImage: "alarm", action: onOpenReminders)
                        }
                        if let list, list.hasArchive {
                            Toggle(isOn: Binding(get: { list.isArchiveExpanded }, set: { list.isArchiveExpanded = $0 })) {
                                Label("Show Archived", systemImage: "archivebox")
                            }
                        }
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal.decrease")
                    }
                }
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button(action: onNewMessage) {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                }
            }
        #endif
    }

    #if os(iOS)
    private var searchText: Binding<String> {
        Binding(get: { list?.filterText ?? "" }, set: { list?.filterText = $0 })
    }
    #endif

    @ViewBuilder
    private var lists: some View {
        if let list {
            if mode == .compact {
                CompactConversationListView(
                    model: list,
                    selection: $selection,
                    composerFocused: $composerFocused
                )
            } else {
                ConversationListView(
                    model: list,
                    selection: $selection,
                    composerFocused: $composerFocused,
                    searchFocusRequest: searchFocusRequest,
                    onSearchFocusHandled: onSearchFocusHandled,
                    draft: draft,
                    onDiscardDraft: onDiscardDraft,
                    reminderCount: reminderCount
                )
            }
        } else {
            Color.clear
        }
    }
}
