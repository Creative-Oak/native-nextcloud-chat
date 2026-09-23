import Foundation

/// Turns a run of audio levels into "they're talking" — what a ring around whoever is
/// speaking needs. It comes on at the first loud moment and goes off only after a quiet
/// stretch, so the pauses between words don't make it blink.
///
/// Levels are WebRTC's own: the loudness of one audio stream from 0 to 1, as the statistics
/// report them for what this Mac sends and for each stream it receives.
struct SpeakingDetector: Sendable, Equatable {
    /// Loud enough to start.
    var onThreshold: Double = 0.02
    /// Quiet enough for the hush to begin; between the two, whatever it was stays.
    var offThreshold: Double = 0.01
    /// How long it has to stay quiet before it stops.
    var hush: TimeInterval = 0.8

    private(set) var isSpeaking = false
    /// When it was last loud enough to count as talking.
    private var lastLoud: Date?

    init(onThreshold: Double = 0.02, offThreshold: Double = 0.01, hush: TimeInterval = 0.8) {
        self.onThreshold = onThreshold
        self.offThreshold = offThreshold
        self.hush = hush
    }

    /// One reading. Returns whether the answer changed, so only a change is passed on.
    @discardableResult
    mutating func update(level: Double, at now: Date = Date()) -> Bool {
        let was = isSpeaking
        if level >= onThreshold {
            lastLoud = now
            isSpeaking = true
        } else if isSpeaking, level < offThreshold, let lastLoud, now.timeIntervalSince(lastLoud) >= hush {
            isSpeaking = false
        }
        return was != isSpeaking
    }

    /// Their stream went away, or the microphone was muted: nobody is talking.
    @discardableResult
    mutating func silence() -> Bool {
        let was = isSpeaking
        isSpeaking = false
        lastLoud = nil
        return was
    }
}
