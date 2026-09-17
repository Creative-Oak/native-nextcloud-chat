import SwiftUI

/// What you missed, sitting on the "New messages" line — the exact place you start reading.
///
/// Drawn as a card that is plainly *not* a message: a sparkles symbol, a caption saying how
/// many messages it read and that it happened on this Mac, and no bubble. A summary that
/// looked like a message would be the worst thing this feature could do, because the one
/// promise a transcript makes is that everything in it was said by somebody.
struct CatchUpCard: View {
    let summary: CatchUp
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)

                Text(summary.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if summary.needsYou {
                    Text("Needs you")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Color.orange.opacity(0.15), in: .capsule)
                        .accessibilityLabel("Somebody is waiting on you")
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide the summary")
                .accessibilityLabel("Hide the summary")
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(summary.points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(point)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12))

            Text("Summary of \(summary.messageCount) messages, written on this Mac. Read them yourself below.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .glass(.panel, cornerRadius: 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What you missed")
    }
}

/// The "New messages" line, which can offer to summarise what is under it.
struct UnreadSeparatorRow: View {
    let state: CatchUpModel.State
    /// Nil where there is nothing worth summarising, or no model to do it with.
    var unreadCount: Int?
    var onCatchUp: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                marker
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if case .ready(let summary) = state {
                CatchUpCard(summary: summary, onDismiss: onDismiss)
            }
        }
        .animation(.smooth(duration: 0.25), value: state)
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Catching you up…")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .fixedSize()

        case .failed:
            Text("New messages — couldn’t summarise those")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

        case .idle, .ready:
            if let unreadCount, case .idle = state {
                Button(action: onCatchUp) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Catch me up on \(unreadCount)")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Summarise what you missed, on this Mac")
                .fixedSize()
            } else {
                Text("New messages")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
    }
}
