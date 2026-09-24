import AppKit
import SwiftUI

/// Reactions on a message, the way Messages shows tapbacks: a badge hanging off the
/// bubble's top corner — the far corner from the sender — with a little thought-bubble
/// tail into it. Yours is filled with the accent colour, everyone else's is grey. A
/// reaction more than one person made carries its count.
struct ReactionBadges: View {
    let reactions: [String: Int]
    let mine: Set<String>
    let isFromMe: Bool
    let isEnabled: Bool
    var onToggle: (String) -> Void

    var body: some View {
        // Most-used first, then alphabetically, so the order is stable as counts change.
        let ordered = reactions.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }

        HStack(spacing: -8) {
            ForEach(Array(ordered.enumerated()), id: \.element.key) { index, entry in
                badge(emoji: entry.key, count: entry.value)
                    .zIndex(Double(ordered.count - index))
            }
        }
        // The tail: two dots trailing down from the badge's outer side, past the
        // bubble's corner rather than over its text — as Messages draws them.
        .overlay(alignment: isFromMe ? .bottomLeading : .bottomTrailing) {
            let color = fill(for: ordered.last?.key ?? "")
            ZStack(alignment: isFromMe ? .topTrailing : .topLeading) {
                Circle().fill(color).frame(width: 9, height: 9)
                Circle().fill(color).frame(width: 4, height: 4)
                    .offset(x: isFromMe ? -6 : 6, y: 9)
            }
            .offset(x: isFromMe ? -2 : 2, y: 6)
        }
        .animation(.smooth(duration: 0.25), value: ordered.map(\.key))
    }

    private func badge(emoji: String, count: Int) -> some View {
        Button { onToggle(emoji) } label: {
            HStack(spacing: 3) {
                Text(emoji).font(.system(size: 14))
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(mine.contains(emoji) ? Color.white : Color.primary)
                }
            }
            .padding(.horizontal, count > 1 ? 9 : 7)
            .frame(height: 28)
            .background(fill(for: emoji), in: .capsule)
            // A hairline in the page colour, so overlapping badges and the bubble
            // underneath read as separate objects.
            .overlay { Capsule().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1.5) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(mine.contains(emoji) ? "Remove your reaction" : "React with \(emoji)")
        .accessibilityLabel("\(emoji), \(count)")
    }

    private func fill(for emoji: String) -> Color {
        mine.contains(emoji) ? Color.accentColor : Color.primary.opacity(0.12)
    }
}

/// A small, fast emoji picker.
///
/// Deliberately not the system character palette: this is one click, stays inside the
/// window, and covers the emoji people actually use in chat. ⌃⌘Space is still there for
/// everything else.
struct EmojiPicker: View {
    var onPick: (String) -> Void
    @State private var search = ""

    static let categories: [(String, [String])] = [
        (String(localized: "Frequent", comment: "Emoji picker category"), ["👍", "❤️", "😂", "🎉", "🙏", "👀", "🔥", "✅"]),
        (String(localized: "Smileys", comment: "Emoji picker category"), ["😀", "😃", "😄", "😁", "😅", "😊", "🙂", "😉", "😍", "🤩", "😘", "😎", "🤔", "🤨",
                     "😐", "😴", "😢", "😭", "😡", "🥳", "🤯", "😱", "🤗", "🙃"]),
        (String(localized: "Gestures", comment: "Emoji picker category"), ["👍", "👎", "👏", "🙌", "🤝", "💪", "✌️", "🤞", "👋", "🫶", "🙏", "☝️"]),
        (String(localized: "Objects", comment: "Emoji picker category"), ["✅", "❌", "⚠️", "💡", "📌", "📎", "🔒", "🚀", "🐛", "☕️", "🍕", "🎂"]),
        (String(localized: "Hearts", comment: "Emoji picker category"), ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "✨", "⭐️", "🌟"])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredCategories, id: \.0) { name, emoji in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 2), count: 8), spacing: 2) {
                                ForEach(emoji, id: \.self) { character in
                                    Button { onPick(character) } label: {
                                        Text(character).font(.system(size: 18))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 240, height: 220)
        }
        .padding(10)
        .glass(.panel)
    }

    private var filteredCategories: [(String, [String])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.categories }
        // Names aren't searchable without an emoji database; filter category names instead
        // and fall back to showing everything, which beats showing nothing.
        let matches = Self.categories.filter { $0.0.localizedStandardContains(query) }
        return matches.isEmpty ? Self.categories : matches
    }
}
