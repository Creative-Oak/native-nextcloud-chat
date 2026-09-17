import SwiftUI

/// The most recent pinned message, over the top of the transcript: who wrote it and what it
/// says, on one line. A click shows the message; the crossed-out eye hides the bar for you until something
/// newer is pinned, and leaves the message pinned for everyone — moderators get an Unpin
/// button beside it for that. With more than one pin, the others are a menu away.
struct PinnedBar: View {
    let model: ChatModel
    let pin: PinnedMessage
    var onShow: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(45))

            Button { onShow(pin.id) } label: {
                Text(summary(of: pin))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show pinned message")

            if model.activePinCount > 1 {
                Menu {
                    PinnedMessagesMenu(model: model, onShow: onShow)
                } label: {
                    Text("\(model.activePinCount) pinned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("All pinned messages")
            }

            // Two different things, so two buttons: Unpin takes the pin away for everyone and
            // is a moderator's; the eye only folds the bar away for you, and anyone may.
            if model.canPin {
                Button { model.unpin(messageID: pin.id) } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Unpin for everyone")
                .accessibilityLabel("Unpin")
            }

            Button(action: model.hidePinnedBar) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide for me, until something new is pinned. It stays pinned for everyone.")
            .accessibilityLabel("Hide pinned message for me")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 460)
        .glass(.panel, cornerRadius: 10)
        .contextMenu {
            Button("Show Message") { onShow(pin.id) }
            if model.canPin {
                Button("Unpin") { model.unpin(messageID: pin.id) }
            }
        }
    }

    private func summary(of pin: PinnedMessage) -> String {
        PinnedMessagesMenu.summary(of: pin, in: model)
    }
}

/// The pins as menu items, newest pin first. Choosing one shows the message.
struct PinnedMessagesMenu: View {
    let model: ChatModel
    var onShow: (Int) -> Void

    var body: some View {
        ForEach(model.activePins) { pin in
            Button(Self.summary(of: pin, in: model)) { onShow(pin.id) }
        }
    }

    static func summary(of pin: PinnedMessage, in model: ChatModel) -> String {
        let text = model.content(for: pin.message).preview
        let author = pin.message.actor.resolvedDisplayName
        return author.isEmpty ? text : "\(author): \(text)"
    }
}
