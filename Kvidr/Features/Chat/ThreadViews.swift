import AppKit
import SwiftUI

/// Over the first message of a thread: what the thread is called.
struct ThreadTitle: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .lineLimit(2)
            .padding(.bottom, 2)
    }
}

/// Under the first message of a thread: how many replies, and the way in — as Messages
/// shows replies under the message they answer.
struct ThreadRepliesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(count == 0 ? "Reply in thread" : "\(count) replies")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Open the thread")
    }
}

/// Over the transcript while a thread is open: which thread, and — anywhere on it — the way
/// back. One line, like the out-of-office bar.
struct ThreadBar: View {
    let thread: MessageThread
    let replies: Int
    let isLoading: Bool
    var onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, height: 16)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)

                Text("\(Text(thread.title.isEmpty ? String(localized: "Thread", comment: "A thread with no title") : thread.title).fontWeight(.medium))\(Text(" · \(String(localized: "\(replies) replies"))").foregroundStyle(.secondary))")
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 12))
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: 460, alignment: .leading)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // Esc when the text field isn't taking it — the field hands it over itself.
        .keyboardShortcut(.cancelAction)
        .help("Back to the conversation (Esc)")
        .accessibilityLabel(thread.title.isEmpty
            ? String(localized: "Back to the conversation, from the thread")
            : String(localized: "Back to the conversation, from \(thread.title)", comment: "%@ is the thread's title"))
        .glass(.panel, cornerRadius: 10)
    }
}

/// The first line of the message field while a thread is being started: its title, set in
/// bold over the message, with a way to change your mind.
struct ThreadTitleField: View {
    @Binding var title: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                TextField("Thread Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused(isFocused)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Don’t start a thread")
                .accessibilityLabel("Don’t start a thread")
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            // On the next turn: the field has only just been put in the composer.
            .task { isFocused.wrappedValue = true }
            Divider()
                .padding(.bottom, 4)
        }
        .padding(.trailing, 4)
    }
}

/// The toolbar's list of threads: each by its title, with how many replies and when it was
/// last busy; the open one ticked.
struct ThreadsMenu: View {
    let model: ChatModel

    var body: some View {
        ForEach(model.threads) { thread in
            Toggle(isOn: Binding(
                get: { model.openThread?.id == thread.id },
                set: { _ in model.showThread(MessageThread(id: thread.id, title: thread.title, replies: thread.replies)) }
            )) {
                Text(thread.title.isEmpty ? String(localized: "Thread", comment: "A thread with no title") : thread.title)
                Text("\(String(localized: "\(thread.replies) replies")) · \(thread.lastActivity.formatted(.relative(presentation: .named)))")
            }
        }
    }
}

/// The thread bar's right-click menu: renaming, and how much the thread notifies.
enum ThreadBarMenu {
    @MainActor
    static func make(
        level: ThreadNotificationLevel,
        onRename: (() -> Void)?,
        onSetLevel: @escaping (ThreadNotificationLevel) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        if let onRename {
            menu.addItem(ClosureMenuItem(String(localized: "Rename Thread…"), symbol: "character.cursor.ibeam", action: onRename))
        }
        let submenu = NSMenu()
        for option in ThreadNotificationLevel.allCases {
            let item = ClosureMenuItem(option.title) { onSetLevel(option) }
            item.state = option == level ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: String(localized: "Thread Notifications"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        item.submenu = submenu
        menu.addItem(item)
        return menu
    }
}

/// Takes right clicks only, and shows the menu made at that moment; left clicks go through
/// to the bar underneath.
struct ThreadBarMenuHost: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> HostView {
        HostView(frame: .zero)
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.makeMenu = makeMenu
    }

    final class HostView: NSView {
        var makeMenu: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isContextClick(event) else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

        override func mouseDown(with event: NSEvent) {
            if Self.isContextClick(event) { showMenu(for: event) } else { super.mouseDown(with: event) }
        }

        private static func isContextClick(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        private func showMenu(for event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
