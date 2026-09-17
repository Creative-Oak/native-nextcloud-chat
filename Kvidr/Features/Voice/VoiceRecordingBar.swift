import SwiftUI

/// The composer while a voice message is being recorded, and after, drawn the way Messages
/// draws it: one wide capsule of red bars and a stop button while recording; then a way to
/// throw it away, a play button, the recording's bars, its length and send.
struct VoiceRecordingBar: View {
    let recorder: VoiceRecorder
    var onSend: () -> Void

    var body: some View {
        switch recorder.phase {
        case .recording:
            recording
        case .recorded, .sending:
            recorded
        case .failed(let message):
            failure(message)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Recording

    private var recording: some View {
        HStack(spacing: 12) {
            LevelBars(
                samples: recorder.samples,
                style: .live
            )
            Text(Self.clock(recorder.elapsed))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.red)
                .fixedSize()
            Button(action: recorder.stop) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.red)
                    .frame(width: 11, height: 11)
                    .frame(width: GlassMetrics.control - 6, height: GlassMetrics.control - 6)
                    .background(Color.red.opacity(0.18), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(.leading, 18)
        .padding(.trailing, 3)
        .frame(height: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Recorded

    private var recorded: some View {
        HStack(spacing: 8) {
            Button(action: recorder.discard) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(recorder.phase == .sending)
            .help("Delete recording")
            .accessibilityLabel("Delete recording")

            HStack(spacing: 12) {
                Button(action: recorder.togglePreview) {
                    Image(systemName: recorder.isPreviewing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: GlassMetrics.control - 8, height: GlassMetrics.control - 8)
                        .background(Color.primary.opacity(0.08), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(recorder.phase == .sending)
                .help(recorder.isPreviewing ? "Pause" : "Listen")

                LevelBars(
                    samples: recorder.samples,
                    style: .recorded(progress: recorder.previewProgress)
                )

                Text(Self.clock(recorder.elapsed))
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .fixedSize()

                if recorder.phase == .sending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: GlassMetrics.control - 8)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.accentColor)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Send voice message")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .frame(height: GlassMetrics.control)
            .glass(.field, cornerRadius: GlassMetrics.control / 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Failure

    private func failure(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("OK", action: recorder.discard)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glass(.panel, cornerRadius: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Minutes and seconds, spelled the way this Mac spells a time — "0:04", or "0.04" in
    /// Danish.
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }
}

/// A row of small rounded bars as wide as there is room for.
///
/// Live, the newest sound is at the trailing edge in red and the room still to fill is faint
/// red; recorded, the whole recording is squeezed into the row in grey, darker where it has
/// been played back.
private struct LevelBars: View {
    enum Style: Equatable {
        case live
        case recorded(progress: Double)
    }

    let samples: [Float]
    let style: Style

    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 2.5
    private static let height: CGFloat = 20
    private static let minimum: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let count = max(Int((proxy.size.width + Self.spacing) / (Self.barWidth + Self.spacing)), 1)
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let bar = bar(at: index, of: count)
                    Capsule()
                        .fill(bar.color)
                        .frame(width: Self.barWidth, height: bar.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func bar(at index: Int, of count: Int) -> (height: CGFloat, color: Color) {
        switch style {
        case .live:
            // Right-aligned: the last `count` samples, with faint stubs in front of them.
            let recent = samples.suffix(count)
            let offset = count - recent.count
            guard index >= offset else { return (Self.minimum, Color.red.opacity(0.35)) }
            let level = recent[recent.startIndex + index - offset]
            return (height(level), Color.red)
        case .recorded(let progress):
            let levels = VoiceRecorder.downsample(samples, to: count)
            let played = Double(index) / Double(count) < progress
            return (height(levels[index]), Color.primary.opacity(played ? 0.8 : 0.35))
        }
    }

    private func height(_ level: Float) -> CGFloat {
        max(Self.minimum, CGFloat(level) * Self.height)
    }
}
