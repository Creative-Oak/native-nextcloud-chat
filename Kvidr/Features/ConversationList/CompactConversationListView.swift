import SwiftUI

/// The sidebar at its narrow width: a column of faces, the way Messages folds its list.
///
/// The same `List` with the same selection as the full list, so the arrow keys, Return
/// and the context menu behave the same; only the row is different. The groups keep their
/// order — favourites, then everything else, then archived — separated by the sidebar's
/// own section spacing, since there is no room for a heading. With no heading there is
/// nothing to fold either, so the archive shows here only while it is open in the full list. No search field either:
/// ⌘F widens the sidebar first, see `RootView`.
struct CompactConversationListView: View {
    @Bindable var model: ConversationListModel
    @Binding var selection: String?
    @Binding var composerFocused: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(model.sections.filter { $0.section != .archived || model.isArchiveExpanded }) { group in
                Section {
                    ForEach(group.items) { conversation in
                        CompactConversationRow(conversation: conversation, isSelected: selection == conversation.token)
                            .tag(conversation.token)
                            .listRowInsets(EdgeInsets(top: SidebarMode.compactRowSpacing / 2, leading: 0, bottom: SidebarMode.compactRowSpacing / 2, trailing: 0))
                            .contextMenu { ConversationContextMenu(model: model, conversation: conversation) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            // Return from the sidebar moves you into the conversation you just picked.
            guard selection != nil else { return .ignored }
            composerFocused = true
            return .handled
        }
    }
}
