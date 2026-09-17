import Foundation
import Observation

/// What a long voice message actually asked for.
///
/// The transcript is already there — kvidr writes voice messages out as they appear. But a
/// ninety-second recording transcribes into a wall of speech, and the one thing the
/// listener needs from it is usually a single sentence buried two thirds of the way in.
///
/// Only long ones. A ten-second "ja, det lyder fint" is already as short as it gets, and
/// putting a summary under it would be a joke at the app's expense.
@MainActor
@Observable
final class VoiceInsightsModel {
    enum State: Equatable {
        case working
        case ready(VoiceGist)
        /// Nothing worth pulling out, or the model declined. Nothing is shown.
        case nothing
    }

    private(set) var states: [String: State] = [:]

    @ObservationIgnored var intelligence: OnDeviceIntelligence?
    @ObservationIgnored var isEnabled = true
    @ObservationIgnored private var queue: Task<Void, Never>?

    /// Shorter than this and there is nothing to summarise — roughly half a minute of talk.
    private static let threshold = 280

    func state(for id: String) -> State? { states[id] }

    /// Called with a transcript as it lands. Each recording is read once.
    ///
    /// No sensitivity gate, deliberately: this sits directly under the transcript, which is
    /// already on screen and was already written out on this Mac. Summarising words the
    /// reader is looking at reveals nothing the bubble didn't.
    func read(id: String, transcript: String) {
        guard isEnabled, states[id] == nil else { return }
        guard let intelligence, intelligence.isReady else { return }
        guard transcript.count >= Self.threshold else { return }

        states[id] = .working
        let previous = queue
        queue = Task { [weak self] in
            // One at a time, behind whatever is already running: several long voice
            // messages scrolling into view at once is a queue, not a stampede.
            await previous?.value
            let gist = await intelligence.gist(ofSpokenMessage: transcript)
            guard !Task.isCancelled, let self else { return }
            if let gist, !gist.summary.isEmpty {
                self.states[id] = .ready(gist)
            } else {
                self.states[id] = .nothing
            }
        }
    }

    /// The transcripts were thrown away — a language change — so these mean nothing now.
    func reset() {
        queue?.cancel()
        queue = nil
        states = [:]
    }
}

/// The short of a long recording.
struct VoiceGist: Sendable, Equatable {
    /// One sentence: what the recording was about.
    var summary: String
    /// What it asked somebody to do, if anything. Often empty, which is fine.
    var actions: [String]
}
