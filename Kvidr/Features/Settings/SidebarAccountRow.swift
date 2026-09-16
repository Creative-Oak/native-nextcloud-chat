import SwiftUI

/// The foot of the sidebar: who is signed in, and the way into Settings.
///
/// Outside the `List` on purpose. Settings is not a conversation, and a row inside the list
/// would take part in arrow-key navigation, type-select and the context menu.
struct SidebarAccountRow: View {
    let profile: ProfileModel
    let mode: SidebarMode
    let isSelected: Bool
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            Group {
                if mode == .compact {
                    ProfileAvatar(profile: profile, size: SidebarMode.compactAvatarSize)
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 10) {
                        ProfileAvatar(profile: profile, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let message = profile.statusMessage {
                                Text([message.icon, message.text].filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : isHovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The 10pt margin a selected conversation's highlight keeps, on the sides and below,
        // so the block sits level with the rows above it and clear of the window's foot.
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings, signed in as \(profile.displayName)")
        .task { await profile.loadStatus() }
    }
}
