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
    /// Upcoming reminders; the Reminders face shows while there are any, as the row does in
    /// the wide sidebar.
    var reminderCount = 0
    /// The face whose menu is open, for its outline.
    @State private var menuToken: String?

    /// The sidebar's sections, each face once: something in two tags is in the first of them
    /// only — two of the same face in a column of faces reads as a mistake.
    private var groups: [ConversationIndex.SectionGroup] {
        var seen = Set<String>()
        return model.sections
            .filter { $0.section != .archived || model.isArchiveExpanded }
            .map { group in
                var unique = group
                unique.items = group.items.filter { seen.insert($0.token).inserted }
                return unique
            }
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        List(selection: $selection) {
            if reminderCount > 0 {
                CompactRemindersRow(count: reminderCount, isSelected: RemindersToken.isReminders(selection))
                    .tag(RemindersToken.value)
                    .listRowInsets(EdgeInsets(top: SidebarMode.compactRowSpacing / 2, leading: 0, bottom: SidebarMode.compactRowSpacing / 2, trailing: 0))
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { conversation in
                        CompactConversationRow(conversation: conversation, isSelected: selection == conversation.token)
                            .tag(conversation.token)
                            .listRowInsets(EdgeInsets(top: SidebarMode.compactRowSpacing / 2, leading: 0, bottom: SidebarMode.compactRowSpacing / 2, trailing: 0))
                            .modifier(ConversationRowMenu(model: model, token: conversation.token, menuToken: $menuToken))
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

/// Reminders in the compact sidebar: an alarm where a face would be, how many on it, and the
/// name beneath — the same shape as a conversation's row.
private struct CompactRemindersRow: View {
    let count: Int
    var isSelected = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "alarm")
                .font(.system(size: SidebarMode.compactAvatarSize * 0.4, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: SidebarMode.compactAvatarSize, height: SidebarMode.compactAvatarSize)
                .background(Color.orange.opacity(0.15), in: .circle)
                .overlay(alignment: .topTrailing) {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: .capsule)
                }
            Text("Reminders")
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SidebarMode.compactRowHeight)
        .contentShape(.rect)
        .help("Reminders")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reminders, \(count) upcoming")
    }
}
