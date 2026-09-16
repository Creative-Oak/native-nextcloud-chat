import AppKit
import SwiftUI

/// The signed-in user's own picture, with their status as a dot.
///
/// Asks again whenever ``ProfileModel/avatarRevision`` moves, so a new picture shows
/// everywhere at once rather than wherever the cache happens to expire first.
struct ProfileAvatar: View {
    let profile: ProfileModel
    var size: CGFloat = 32
    var showsStatus = true

    @Environment(\.avatarLoader) private var loader
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Circle().fill(.quaternary)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(tint.gradient)
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsStatus, profile.statusSupport != nil, let status = profile.status?.status {
                StatusDot(status: status, diameter: max(8, size * 0.3))
            }
        }
        .task(id: "\(profile.userID)-\(profile.avatarRevision)-\(colorScheme == .dark)-\(size)") { await load() }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = profile.displayName.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private var tint: Color {
        var hash: UInt64 = 5381
        for byte in profile.userID.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: colorScheme == .dark ? 0.7 : 0.78)
    }

    private func load() async {
        guard let loader else { return }
        let subject = AvatarLoader.Subject.user(id: profile.userID)
        let pixels = Int(size * 2)
        let isDark = colorScheme == .dark
        if let cached = loader.cachedImage(for: subject, size: pixels, dark: isDark) {
            image = cached
            return
        }
        let fetched = await loader.image(for: subject, size: pixels, dark: isDark)
        withAnimation(.easeOut(duration: 0.15)) { image = fetched }
    }
}

/// A status as Nextcloud colours it: green online, yellow away, red do-not-disturb and busy,
/// an empty ring for invisible.
struct StatusDot: View {
    let status: OnlineStatus
    var diameter: CGFloat = 10

    var body: some View {
        Group {
            switch status {
            case .invisible, .offline:
                Circle().strokeBorder(Color.secondary, lineWidth: max(1.5, diameter * 0.2))
            default:
                Circle().fill(color)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(.background).padding(-max(1.5, diameter * 0.18)))
        .accessibilityLabel(status.title)
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .away: .yellow
        case .dnd, .busy: .red
        case .invisible, .offline: .secondary
        }
    }
}
