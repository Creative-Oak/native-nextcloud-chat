import SwiftUI

/// A voice message as Messages draws one: a play button, the recording's waveform filling in
/// as it plays, its length, and what was said written underneath.
struct VoiceMessageView: View {
    let object: RichObject
    var isFromMe = false

    @Environment(\.voicePlayer) private var player

    var body: some View {
        if let player {
            content(player)
                // Again when the transcripts are reset, so a new language reaches the voice
                // messages already on screen.
                .task(id: "\(object.id)#\(player.transcriber.generation)") { await player.load(object) }
        }
    }

    private func content(_ player: VoicePlayer) -> some View {
        let state = player.state(of: object)
        let isCurrent = player.currentID == object.id
        let isPlaying = isCurrent && player.isPlaying

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback(of: object)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isFromMe ? Color.accentColor : Color.white)
                        .frame(width: 28, height: 28)
                        .background(isFromMe ? Color.white : Color.accentColor, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(!state.canPlay)
                .help(isPlaying ? "Pause" : "Play")
                .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")

                Waveform(
                    levels: state.levels,
                    progress: player.progress(of: object),
                    isFromMe: isFromMe
                ) { fraction in
                    player.seek(object, to: fraction)
                }
                .disabled(!state.canPlay)

                Text(timeText(player, state: state, isCurrent: isCurrent))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .fixedSize()
            }

            if let problem = state.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(secondary)
            } else if case .done(let text) = player.transcriber.state(for: object.id) {
                // A long one can be put in a sentence or two, above the words themselves.
                if let summary = player.transcriber.summaries[object.id] {
                    Label {
                        Text(summary ?? "Summarizing…")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "apple.intelligence")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isFromMe ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 260, alignment: .leading)
                }
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
                if text.count > VoiceTranscriber.summarizableLength, player.transcriber.summaries[object.id] == nil,
                   UnreadSummary.availability != .unsupported {
                    Button("Summarize") { player.transcriber.summarize(id: object.id) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .tint(isFromMe ? .white : .accentColor)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice message")
    }

    private var secondary: Color {
        isFromMe ? Color.white.opacity(0.75) : Color.secondary
    }

    /// The length, and while playing, what is left of it — as Messages counts.
    private func timeText(_ player: VoicePlayer, state: VoicePlayer.LoadState, isCurrent: Bool) -> String {
        guard case .ready(let duration, _) = state else { return "–:––" }
        return Self.clock(isCurrent ? max(duration - player.position, 0) : duration)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension VoicePlayer.LoadState {
    var canPlay: Bool {
        if case .ready = self { true } else { false }
    }

    var levels: [Float] {
        if case .ready(_, let levels) = self { return levels }
        return Array(repeating: 0.12, count: VoicePlayer.barCount)
    }

    var problem: String? {
        switch self {
        case .unplayable: "This Mac can’t play this recording"
        case .failed(let reason): reason
        default: nil
        }
    }
}

/// The bars: the part already played at full strength, the rest faint. Click or drag along
/// it to jump.
private struct Waveform: View {
    let levels: [Float]
    let progress: Double
    let isFromMe: Bool
    var onSeek: (Double) -> Void

    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 2
    private static let height: CGFloat = 26

    var body: some View {
        let color = isFromMe ? Color.white : Color.primary
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(levels.indices, id: \.self) { index in
                let played = Double(index) / Double(max(levels.count, 1)) < progress
                Capsule()
                    .fill(color.opacity(played ? 1 : (isFromMe ? 0.5 : 0.3)))
                    .frame(width: Self.barWidth, height: max(3, CGFloat(levels[index]) * Self.height))
            }
        }
        .frame(height: Self.height)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let width = CGFloat(levels.count) * (Self.barWidth + Self.spacing)
                    onSeek(Double(value.location.x / max(width, 1)))
                }
        )
        .animation(.linear(duration: 0.1), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
