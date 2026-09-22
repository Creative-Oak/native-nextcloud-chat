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
                Text(count == 0 ? "Reply in thread" : count == 1 ? "1 reply" : "\(count) replies")
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

                Text("\(Text(thread.title.isEmpty ? "Thread" : thread.title).fontWeight(.medium))\(Text(" · \(replies == 1 ? "1 reply" : "\(replies) replies")").foregroundStyle(.secondary))")
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
        .accessibilityLabel("Back to the conversation, from \(thread.title.isEmpty ? "the thread" : thread.title)")
        .glass(.panel, cornerRadius: 10)
    }
}
