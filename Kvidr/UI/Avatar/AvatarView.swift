import AppKit
import SwiftUI

/// A conversation or person avatar, with an attractive fallback.
///
/// Never blocks: the fallback renders immediately and the fetched image fades in when (and
/// if) it arrives. A conversation row must never wait on the network to draw.
struct AvatarView: View {
    let conversation: Conversation
    var size: CGFloat = 34

    @Environment(\.avatarLoader) private var loader
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            // One or the other, never both. The server's icons for groups and Note to
            // self have transparent backgrounds, and drawn over the fallback they came
            // out as two pictures on top of each other. They get a plain disc instead.
            if let image {
                Circle().fill(.quaternary)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            // A hairline keeps light avatars from bleeding into a light sidebar.
            Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) { statusIndicator }
        .task(id: taskID) { await load() }
        .accessibilityHidden(true)
    }

    private var taskID: String {
        let revision = conversation.isOneToOne ? loader?.revision(ofUser: conversation.name) ?? 0 : 0
        return "\(conversation.token)-\(conversation.avatarVersion)-\(colorScheme == .dark)-\(revision)"
    }

    @ViewBuilder
    private var fallback: some View {
        switch conversation.type {
        case .noteToSelf:
            symbolFallback("note.text", tint: .secondary)
        case .publicRoom:
            symbolFallback("globe", tint: tint)
        case .group, .changelog:
            symbolFallback("person.2.fill", tint: tint)
        case .oneToOne, .formerOneToOne:
            initialsFallback
        }
    }

    private var initialsFallback: some View {
        Circle()
            .fill(tint.gradient)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
    }

    private func symbolFallback(_ symbol: String, tint: Color) -> some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(tint)
            }
    }

    private var initials: String {
        let words = conversation.displayName
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Deterministic hue from the name, so a given person always gets the same colour.
    private var tint: Color {
        let seed = conversation.isOneToOne ? conversation.name : conversation.token
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: colorScheme == .dark ? 0.7 : 0.78)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if conversation.isOneToOne, let status = conversation.userStatus, status.isOnline || status.isDoNotDisturb {
            Circle()
                .fill(status.isDoNotDisturb ? Color.red : Color.green)
                .frame(width: size * 0.28, height: size * 0.28)
                .overlay { Circle().strokeBorder(.background, lineWidth: size * 0.055) }
        }
    }

    private func load() async {
        guard let loader else { return }
        let subject: AvatarLoader.Subject = if conversation.isOneToOne, !conversation.name.isEmpty {
            .user(id: conversation.name)
        } else {
            .conversation(token: conversation.token, version: conversation.avatarVersion)
        }
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

/// A person's avatar inside the chat transcript.
struct ActorAvatarView: View {
    let actor: MessageActor
    var size: CGFloat = 28

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
                if actor.isBot {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                } else if actor.isDeletedUser {
                    Image(systemName: "person.slash.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: "\(actor.id)-\(loader?.revision(ofUser: actor.id) ?? 0)") { await load() }
        .accessibilityLabel(actor.resolvedDisplayName)
    }

    private var initials: String {
        let name = actor.resolvedDisplayName
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private var tint: Color {
        var hash: UInt64 = 5381
        for byte in actor.id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: colorScheme == .dark ? 0.7 : 0.78)
    }

    private func load() async {
        guard let loader, actor.kind == .users, !actor.id.isEmpty else { return }
        let subject = AvatarLoader.Subject.user(id: actor.id)
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

private struct AvatarLoaderKey: EnvironmentKey {
    static let defaultValue: AvatarLoader? = nil
}

extension EnvironmentValues {
    var avatarLoader: AvatarLoader? {
        get { self[AvatarLoaderKey.self] }
        set { self[AvatarLoaderKey.self] = newValue }
    }
}
