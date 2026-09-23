import AVFoundation
import FoundationModels
import Observation
import Speech

/// Writes voice messages out as text, on this Mac, as soon as they are on screen — the way
/// Messages does.
///
/// Apple's general transcriber is used where it knows the language, and its dictation model
/// otherwise: the dictation model is the one that covers Danish. Either may need the
/// language's model downloaded by macOS the first time. One recording at a time, and each
/// only once per session.
@MainActor
@Observable
final class VoiceTranscriber {
    enum State: Equatable {
        case working
        case done(String)
        /// Nothing to show: no speech, or no model for the language. Not retried.
        case unavailable
    }

    private(set) var states: [String: State] = [:]
    /// Summaries of long transcripts, asked for one by one: nil while being written, a
    /// problem said in place of a summary when it couldn't be.
    private(set) var summaries: [String: String?] = [:]

    /// Transcripts longer than this get the offer of a summary — a minute or so of talking.
    static let summarizableLength = 400
    /// Goes up whenever transcripts are thrown away, so what is on screen asks again — and
    /// so a transcription still running in the old language can't land afterwards.
    private(set) var generation = 0

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func state(for id: String) -> State? { states[id] }

    /// The language transcription uses: the one chosen in Settings, or the Mac's own.
    var locale: Locale {
        preferences.transcriptionLanguage.map(Locale.init(identifier:)) ?? Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }

    func transcribe(id: String, audio: DecodedAudio) {
        guard preferences.transcribesVoiceMessages, states[id] == nil else { return }
        states[id] = .working
        let previous = queue
        let locale = self.locale
        let generation = self.generation
        queue = Task { [weak self] in
            await previous?.value
            let text: String?
            do {
                text = try await Self.transcribe(audio, locale: locale)
            } catch {
                Log.ui.warning("Couldn’t transcribe a voice message: \(error.localizedDescription)")
                text = nil
            }
            guard let self, self.generation == generation else { return }
            if let text, !text.isEmpty {
                self.states[id] = .done(text)
            } else {
                self.states[id] = .unavailable
            }
        }
    }

    /// A sentence or two on what a long voice message says, written on this Mac.
    func summarize(id: String) {
        guard case .done(let text) = states[id], summaries[id] == nil else { return }
        summaries[id] = .some(nil)
        Task { [weak self] in
            let summary: String
            if case .available = UnreadSummary.availability {
                let session = LanguageModelSession(instructions: """
                    You summarize a transcribed voice message in one or two short sentences, in \
                    the language it is spoken in. Only what it says; no introduction.
                    """)
                summary = (try? await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? "The summary couldn’t be written."
            } else if case .notYet(let reason) = UnreadSummary.availability {
                summary = reason
            } else {
                summary = "Summaries need Apple Intelligence, which this Mac doesn’t have."
            }
            self?.summaries[id] = .some(summary)
        }
    }

    /// Forgets every transcript, and has the voice messages on screen transcribed again —
    /// the language changed, so the old ones are in the wrong one.
    func reset() {
        queue?.cancel()
        queue = nil
        states = [:]
        summaries = [:]
        generation += 1
    }

    /// Every language either model can transcribe, for the Settings picker.
    nonisolated static func supportedLanguages() async -> [Locale] {
        let general = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        var seen = Set<String>()
        return (general + dictation)
            .filter { seen.insert($0.identifier(.bcp47)).inserted }
            .sorted { name(of: $0) < name(of: $1) }
    }

    nonisolated static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private enum TranscriptionError: Error {
        case languageNotSupported
        case noAudioFormat
    }

    nonisolated private static func transcribe(_ audio: DecodedAudio, locale: Locale) async throws -> String {
        let module: any SpeechModule
        let collect: @Sendable () async throws -> String

        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            module = transcriber
            collect = {
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
            module = transcriber
            collect = {
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text
            }
        } else {
            throw TranscriptionError.languageNotSupported
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let buffer = pcmBuffer(audio, in: format)
        else { throw TranscriptionError.noAudioFormat }

        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { try await collect() }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The decoded samples, converted to the format the model asks for.
    nonisolated private static func pcmBuffer(_ audio: DecodedAudio, in target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = input.floatChannelData?[0]
        else { return nil }
        audio.samples.withUnsafeBufferPointer { samples in
            channel.update(from: samples.baseAddress!, count: samples.count)
        }
        input.frameLength = AVAudioFrameCount(audio.samples.count)
        if source == target { return input }

        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}
