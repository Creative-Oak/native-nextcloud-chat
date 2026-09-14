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

    var body: some View {
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
                    onSearchFocusHandled: onSearchFocusHandled
                )
            }
        } else {
            Color.clear
        }
    }
}
