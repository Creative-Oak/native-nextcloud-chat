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
    /// Conversations with something unread, for the Catch Up row.
    var catchUpCount = 0
    var onOpenSettings: () -> Void = {}

    var body: some View {
        lists
            // A bar rather than an inset, as the chat's header is: the list scrolls under it
            // behind the system's edge effect, hard so no row shows through the name.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let profile {
                    SidebarAccountRow(
                        profile: profile,
                        mode: mode,
                        isSelected: SettingsToken.isSettings(selection),
                        onOpen: onOpenSettings
                    )
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
    }

    @ViewBuilder
    private var lists: some View {
        if let list {
            if mode == .compact {
                CompactConversationListView(
                    model: list,
                    selection: $selection,
                    composerFocused: $composerFocused,
                    reminderCount: reminderCount
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
                    reminderCount: reminderCount,
                    catchUpCount: catchUpCount
                )
            }
        } else {
            Color.clear
        }
    }
}
