import AppKit
import SwiftUI

// MARK: - The floating bar

/// The reactions that float above a message you press and hold, the way Messages'
/// tapbacks do: the quick set first, the rest of the picker's emoji after them in a strip
/// that scrolls sideways, and a smiley beside it for anything else.
struct TapbackBar: View {
    let message: Message
    var onReact: (String) -> Void
    var onDone: () -> Void

    @State private var isShowingPicker = false

    /// Seven in view; the rest a swipe away.
    private static let visibleCount = 7
    private static let cell: CGFloat = 40

    /// The quick reactions, then everything the picker offers that they don't.
    static let emoji: [String] = {
        var seen = Set(ChatModel.quickReactions)
        var all = ChatModel.quickReactions
        for (_, group) in EmojiPicker.categories {
            for emoji in group where seen.insert(emoji).inserted {
                all.append(emoji)
            }
        }
        return all
    }()

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Self.emoji, id: \.self) { emoji in
                        TapbackEmoji(emoji: emoji, isMine: message.myReactions.contains(emoji)) {
                            onReact(emoji)
                            onDone()
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(width: CGFloat(Self.visibleCount) * Self.cell + 4, height: Self.cell + 8)
            // The strip fades out at its far end: a hint that it goes on.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            }
            .glass(.panel, cornerRadius: 26)

            Button {
                isShowingPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.cell + 4, height: Self.cell + 4)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("Another reaction")
            .accessibilityLabel("Another Reaction")
            .popover(isPresented: $isShowingPicker, arrowEdge: .bottom) {
                EmojiPicker { emoji in
                    isShowingPicker = false
                    onReact(emoji)
                    onDone()
                }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

/// One reaction in the bar or the menu: grows under the pointer, marked when it is yours.
private struct TapbackEmoji: View {
    let emoji: String
    let isMine: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 38, height: 38)
                .background {
                    if isMine {
                        Circle().fill(Color.accentColor.opacity(0.22))
                    }
                }
                .scaleEffect(isHovering ? 1.3 : 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isHovering)
        .help(isMine ? "Remove your reaction" : "React with \(emoji)")
        .accessibilityLabel(isMine ? "Remove \(emoji) reaction" : "React with \(emoji)")
    }
}

/// Where the message being reacted to sits, published by its row so the transcript can
/// float the bar above it.
struct TapbackAnchor {
    var bounds: Anchor<CGRect>
    var isFromMe: Bool
}

struct TapbackAnchorKey: PreferenceKey {
    static let defaultValue: [Int: TapbackAnchor] = [:]
    static func reduce(value: inout [Int: TapbackAnchor], nextValue: () -> [Int: TapbackAnchor]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - The right-click menu

/// What a message's menu can do. The row fills this in; the menu is built from it.
struct MessageMenuActions {
    var canReply: Bool
    var canEdit: Bool
    var canDelete: Bool
    var canReact: Bool
    var hasReactions: Bool
    var myReactions: Set<String>
    var onReply: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onCopy: () -> Void
    var onReact: (String) -> Void
    var onShowReactions: () -> Void
    var onMoreReactions: () -> Void
    /// The web links in the message, so the menu can offer one to copy. `Copy` copies the
    /// words; a link's label is whatever the sender typed, and the two are allowed to
    /// disagree, so copying the label is no way to find out where a link goes. See
    /// ``MessageContent/webLinks``.
    var links: [URL] = []
}

/// Right-click on a message: the reactions in two rows on top, then the actions — one
/// menu, as in Messages. Built with AppKit's menu rather than SwiftUI's `contextMenu`,
/// which can hold only buttons and submenus, not a row of reactions.
///
/// An invisible view over the row that takes part in hit-testing only for a right click
/// (or a control-click), so hovering, selecting text and clicking links underneath carry
/// on as before.
struct MessageMenuHost: NSViewRepresentable {
    let actions: MessageMenuActions

    func makeNSView(context: Context) -> RightClickView {
        RightClickView(frame: .zero)
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.actions = actions
    }

    final class RightClickView: NSView {
        var actions: MessageMenuActions?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isContextClick(event) else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isContextClick(event) { showMenu(for: event) } else { super.mouseDown(with: event) }
        }

        private static func isContextClick(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        private func showMenu(for event: NSEvent) {
            guard let actions else { return }
            let menu = MessageMenu.make(actions)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

enum MessageMenu {
    /// The second row: a handful more, and the way to the rest.
    fileprivate static let moreReactions = ["🔥", "✅", "😊", "😍", "🤔"]

    /// A link as a menu item reads. The whole thing, up to the point where a menu stops
    /// being readable — it is shown to answer one question, and a truncated answer to
    /// "where does this actually go" is still better than none.
    private static func shortened(_ url: URL) -> String {
        let text = url.absoluteString
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    @MainActor
    static func make(_ actions: MessageMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if actions.canReact {
            let rows = NSMenuItem()
            let host = NSHostingView(rootView: MenuReactionRows(actions: actions) { [weak menu] in menu?.cancelTracking() })
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            rows.view = host
            menu.addItem(rows)
            menu.addItem(.separator())
        }

        if actions.canReply {
            menu.addItem(ClosureMenuItem("Reply", symbol: "arrowshape.turn.up.left", action: actions.onReply))
        }
        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc", action: actions.onCopy))
        for link in actions.links {
            let title = actions.links.count == 1 ? "Copy Link" : "Copy \(shortened(link))"
            menu.addItem(ClosureMenuItem(title, symbol: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            })
        }
        if actions.canEdit {
            menu.addItem(ClosureMenuItem("Edit…", symbol: "pencil", action: actions.onEdit))
        }
        if actions.hasReactions {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show Who Reacted", symbol: "person.2", action: actions.onShowReactions))
        }
        if actions.canDelete {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete…", symbol: "trash", action: actions.onDelete))
        }
        return menu
    }
}

/// A menu item that runs a closure. `NSMenuItem` wants a target and a selector; this is
/// both.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

/// The two rows of reactions at the top of the menu.
private struct MenuReactionRows: View {
    let actions: MessageMenuActions
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            row(ChatModel.quickReactions)
            HStack(spacing: 2) {
                row(MessageMenu.moreReactions)
                Button {
                    dismiss()
                    actions.onMoreReactions()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Another reaction")
                .accessibilityLabel("Another Reaction")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func row(_ emoji: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(emoji, id: \.self) { emoji in
                TapbackEmoji(emoji: emoji, isMine: actions.myReactions.contains(emoji)) {
                    dismiss()
                    actions.onReact(emoji)
                }
            }
        }
    }
}
