import AVFoundation
import Observation
import SwiftUI

/// Plays voice messages and other audio shared into conversations, one at a time.
///
/// The sound is fetched over WebDAV and held in memory — a voice message is tens or hundreds
/// of kilobytes — and never written to disk: the cache is encrypted, and a plaintext copy of
/// someone's voice in a temporary folder would undo that. What is kept is bounded, and goes
/// with the session.
@MainActor
@Observable
final class VoicePlayer {
    enum LoadState: Equatable {
        case idle
        case loading
        /// `levels` are the waveform's bar heights, 0…1.
        case ready(duration: TimeInterval, levels: [Float])
        /// Downloaded, but not something this Mac can play (Ogg, for one).
        case unplayable
        case failed(String)
    }

    /// The file playing or paused, if any.
    private(set) var currentID: String?
    private(set) var isPlaying = false
    /// Seconds into the current file.
    private(set) var position: TimeInterval = 0
    private(set) var states: [String: LoadState] = [:]

    @ObservationIgnored private let session: Session
    @ObservationIgnored let transcriber: VoiceTranscriber
    /// What the long ones came to — see ``VoiceInsightsModel``.
    @ObservationIgnored let insights = VoiceInsightsModel()
    @ObservationIgnored private var data: [String: Data] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var finishObserver: FinishObserver?

    /// How many bars a waveform has.
    nonisolated static let barCount = 40

    /// About this many voice messages' worth.
    private static let memoryBudget = 40 * 1024 * 1024

    init(session: Session, transcriber: VoiceTranscriber) {
        self.session = session
        self.transcriber = transcriber
    }

    func state(of object: RichObject) -> LoadState {
        states[object.id] ?? .idle
    }

    func progress(of object: RichObject) -> Double {
        guard currentID == object.id, case .ready(let duration, _) = state(of: object), duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Fetches the file, learns its length and the shape of its waveform, and hands it to the
    /// transcriber — without playing it, so a message shows all of that before anyone
    /// presses play.
    func load(_ object: RichObject) async {
        let id = object.id
        if let bytes = data[id] {
            // Already here — but its transcript may have been thrown away since.
            if transcriber.state(for: id) == nil { await transcribe(bytes, id: id) }
            return
        }
        if states[id] == .unplayable { return }
        if let existing = inFlight[id] {
            await existing.value
            return
        }
        states[id] = .loading
        let attachments = session.attachments
        let task = Task { [weak self] in
            do throws(TalkError) {
                let bytes = try await attachments.downloadSharedFile(object)
                guard let self else { return }
                guard let probe = try? AVAudioPlayer(data: bytes) else {
                    self.states[id] = .unplayable
                    return
                }
                // Decoded off the main actor: a minute of speech is a few million samples.
                let decoded = try? await Task.detached(priority: .utility) { () throws(AudioDecodingError) -> DecodedAudio in
                    try AudioDecoder.decode(bytes)
                }.value
                self.keep(bytes, for: id)
                self.states[id] = .ready(
                    duration: probe.duration,
                    levels: decoded?.levels(count: Self.barCount) ?? Array(repeating: 0.3, count: Self.barCount)
                )
                if let decoded { self.transcriber.transcribe(id: id, audio: decoded) }
            } catch {
                self?.states[id] = .failed(error.userMessage)
            }
        }
        inFlight[id] = task
        await task.value
        inFlight[id] = nil
    }

    private func transcribe(_ bytes: Data, id: String) async {
        let decoded = try? await Task.detached(priority: .utility) { () throws(AudioDecodingError) -> DecodedAudio in
            try AudioDecoder.decode(bytes)
        }.value
        if let decoded { transcriber.transcribe(id: id, audio: decoded) }
    }

    func togglePlayback(of object: RichObject) {
        if currentID == object.id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTicking()
            } else {
                player.play()
                isPlaying = true
                startTicking()
            }
            return
        }
        Task { await play(object, from: 0) }
    }

    /// Jumps to a point, given as a fraction of the whole, and plays from there.
    func seek(_ object: RichObject, to fraction: Double) {
        guard case .ready(let duration, _) = state(of: object) else { return }
        let time = duration * min(max(fraction, 0), 1)
        if currentID == object.id, let player {
            player.currentTime = time
            position = time
            if !player.isPlaying { togglePlayback(of: object) }
        } else {
            Task { await play(object, from: time) }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        position = 0
        stopTicking()
    }

    private func play(_ object: RichObject, from time: TimeInterval) async {
        await load(object)
        guard let bytes = data[object.id], let player = try? AVAudioPlayer(data: bytes) else { return }
        stop()
        let observer = FinishObserver { [weak self] in self?.finished() }
        player.delegate = observer
        player.currentTime = time
        player.prepareToPlay()
        player.play()
        finishObserver = observer
        self.player = player
        currentID = object.id
        position = time
        isPlaying = true
        startTicking()
    }

    private func finished() {
        isPlaying = false
        position = 0
        currentID = nil
        player = nil
        stopTicking()
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func keep(_ bytes: Data, for id: String) {
        data[id] = bytes
        order.removeAll { $0 == id }
        order.append(id)
        while data.values.reduce(0, { $0 + $1.count }) > Self.memoryBudget, let oldest = order.first, oldest != currentID {
            order.removeFirst()
            data[oldest] = nil
            states[oldest] = nil
        }
    }
}

/// `AVAudioPlayerDelegate` wants an `NSObject`; the player keeps the rest of its state in
/// the `@Observable` class above.
private final class FinishObserver: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}

private struct VoicePlayerKey: EnvironmentKey {
    static let defaultValue: VoicePlayer? = nil
}

extension EnvironmentValues {
    var voicePlayer: VoicePlayer? {
        get { self[VoicePlayerKey.self] }
        set { self[VoicePlayerKey.self] = newValue }
    }
}
