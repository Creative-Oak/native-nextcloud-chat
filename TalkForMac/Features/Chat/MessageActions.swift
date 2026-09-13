import AppKit
import SwiftUI

/// The action strip that appears on hover.
///
/// Hidden until the pointer is over the message: the transcript stays clean, and the
/// actions are exactly where you expect when you want them.
struct MessageHoverActions: View {
    let message: Message
    let capabilities: TalkCapabilities
    let canEdit: Bool
    let canDelete: Bool

    var onReply: (Message) -> Void
    var onEdit: (Message) -> Void
    var onDelete: (Message) -> Void
    var onReact: (String, Message) -> Void

    @State private var isShowingEmojiPicker = false
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: GlassSpacing.distinct) {
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if capabilities.supportsReactions {
                ForEach(ChatModel.quickReactions.prefix(3), id: \.self) { emoji in
                    Button { onReact(emoji, message) } label: {
                        Text(emoji).font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("React with \(emoji)")
                }

                Button { isShowingEmojiPicker = true } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.borderless)
                .help("Add Reaction")
                .popover(isPresented: $isShowingEmojiPicker, arrowEdge: .bottom) {
                    EmojiPicker { emoji in
                        onReact(emoji, message)
                        isShowingEmojiPicker = false
                    }
                }
            }

            if message.isReplyable && capabilities.supportsReplies {
                Button { onReply(message) } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderless)
                .help("Reply")
            }

            Menu {
                MessageContextMenu(
                    message: message, content: nil, capabilities: capabilities,
                    canEdit: canEdit, canDelete: canDelete,
                    onReply: onReply, onEdit: onEdit, onDelete: onDelete, onReact: onReact
                )
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("More")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glass(.floating, cornerRadius: 9)
        .glassEffectID("message-actions", in: glassNamespace)
    }
}

/// Right-click, and the contents of the "More" menu. One definition, two places, so they
/// can never drift apart.
struct MessageContextMenu: View {
    let message: Message
    /// Supplied when the caller already parsed the message, so Copy copies what is on screen.
    let content: MessageContent?
    let capabilities: TalkCapabilities
    let canEdit: Bool
    let canDelete: Bool

    var onReply: (Message) -> Void
    var onEdit: (Message) -> Void
    var onDelete: (Message) -> Void
    var onReact: (String, Message) -> Void

    var body: some View {
        if message.isReplyable && capabilities.supportsReplies {
            Button("Reply") { onReply(message) }
        }

        if capabilities.supportsReactions {
            Menu("React") {
                ForEach(ChatModel.quickReactions, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji, message) }
                }
            }
        }

        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyableText, forType: .string)
        }

        if canEdit {
            Button("Edit…") { onEdit(message) }
        }

        Divider()

        if canDelete {
            Button("Delete", role: .destructive) { onDelete(message) }
        }
    }

    private var copyableText: String {
        if let content { return content.preview }
        return MessageContentParser(currentUserID: "", markdownEnabled: false).parse(message).preview
    }
}

/// Reactions under a message.
struct ReactionStrip: View {
    let reactions: [String: Int]
    let mine: Set<String>
    let isEnabled: Bool
    var onToggle: (String) -> Void

    @Namespace private var namespace

    var body: some View {
        // Most-used first, then alphabetically, so the order is stable as counts change.
        let ordered = reactions.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }

        // A container with generous spacing: neighbouring pills merge into one glass shape,
        // and a new reaction flows out of the pill beside it instead of popping into place.
        GlassEffectContainer(spacing: GlassSpacing.merging) {
            HStack(spacing: 4) {
                ForEach(ordered, id: \.key) { emoji, count in
                    Button { onToggle(emoji) } label: {
                        HStack(spacing: 3) {
                            Text(emoji).font(.system(size: 11))
                            if count > 1 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(mine.contains(emoji) ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .glass(mine.contains(emoji) ? .selectedChip : .chip)
                    .glassEffectID(emoji, in: namespace)
                    .disabled(!isEnabled)
                    .help(mine.contains(emoji) ? "Remove your reaction" : "React with \(emoji)")
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: ordered.map(\.key))
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

    private static let categories: [(String, [String])] = [
        ("Frequent", ["👍", "❤️", "😂", "🎉", "🙏", "👀", "🔥", "✅"]),
        ("Smileys", ["😀", "😃", "😄", "😁", "😅", "😊", "🙂", "😉", "😍", "🤩", "😘", "😎", "🤔", "🤨",
                     "😐", "😴", "😢", "😭", "😡", "🥳", "🤯", "😱", "🤗", "🙃"]),
        ("Gestures", ["👍", "👎", "👏", "🙌", "🤝", "💪", "✌️", "🤞", "👋", "🫶", "🙏", "☝️"]),
        ("Objects", ["✅", "❌", "⚠️", "💡", "📌", "📎", "🔒", "🚀", "🐛", "☕️", "🍕", "🎂"]),
        ("Hearts", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "✨", "⭐️", "🌟"])
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
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Self.categories }
        // Names aren't searchable without an emoji database; filter category names instead
        // and fall back to showing everything, which beats showing nothing.
        let matches = Self.categories.filter { $0.0.lowercased().contains(query) }
        return matches.isEmpty ? Self.categories : matches
    }
}
