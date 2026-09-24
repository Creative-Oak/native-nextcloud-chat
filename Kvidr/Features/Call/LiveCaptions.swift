import Accelerate
import AVFoundation
import Observation
import Speech
@preconcurrency import LiveKitWebRTC

/// Live Captions: what everyone in the call says, written out as they say it — by Apple's
/// speech models, on this Mac. No audio leaves it for this.
///
/// Every voice gets a model of its own, so each line says who is talking, a group call's
/// included. The voices come from WebRTC: each other person's audio as it arrives, and this
/// Mac's microphone after WebRTC's echo cancellation and noise suppression — what is captioned
/// is what the others hear. Nothing is captioned while you're muted.
@MainActor
@Observable
final class LiveCaptions {
    enum Status: Equatable {
        case off
        /// Finding the model, or macOS downloading it: what to say meanwhile.
        case preparing(String)
        case on
        case problem(String)
    }

    private(set) var status: Status = .off
    private(set) var log = CaptionLog()
    /// The language captions are in, once they're on.
    private(set) var language: Locale?
    /// The languages the call's menu offers: the Mac's own that a model covers, and the one
    /// chosen in Settings. The full list is in Settings.
    private(set) var choices: [Locale] = []

    var isOn: Bool { preferences.showsCallCaptions }
    /// The chosen language; nil follows the Mac's own.
    var chosenLanguage: String? { preferences.captionLanguage }

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var voices: [String: Voice] = [:]
    @ObservationIgnored private var listeners: [String: VoiceListener] = [:]
    @ObservationIgnored private var trackTaps: [String: TrackTap] = [:]
    @ObservationIgnored private var model: CaptionModel?
    @ObservationIgnored private var preparing: Task<Void, Never>?

    /// Whose voice, and where it comes from.
    private struct Voice {
        var name: String
        let source: Source
    }

    private enum Source {
        case microphone(MicrophoneTap)
        case track(LKRTCAudioTrack)
    }

    static let ownVoiceID = "microphone"

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - From the call

    /// The call has started: captions come on if they were on last time.
    func begin() {
        if choices.isEmpty { Task { await findChoices() } }
        guard isOn, model == nil, preparing == nil else { return }
        prepare()
    }

    func addMicrophone(_ tap: MicrophoneTap) {
        add(Voice(name: String(localized: "You", comment: "Speaker name over your own lines in Live Captions"), source: .microphone(tap)), id: Self.ownVoiceID)
    }

    func add(track: LKRTCAudioTrack, id: String, name: String) {
        add(Voice(name: name, source: .track(track)), id: id)
    }

    private func add(_ voice: Voice, id: String) {
        stopListening(to: id)
        voices[id] = voice
        if model != nil { listen(to: id) }
    }

    /// They left the call.
    func remove(id: String) {
        stopListening(to: id)
        voices[id] = nil
    }

    /// The call is over, or its media is starting again: every voice goes; the language
    /// stays ready for when they come back.
    func removeAll() {
        for id in Array(voices.keys) { remove(id: id) }
    }

    // MARK: - From the menu

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        preferences.showsCallCaptions = on
        if on {
            prepare()
        } else {
            preparing?.cancel()
            preparing = nil
            for id in Array(listeners.keys) { stopListening(to: id) }
            model = nil
            log.clear()
            status = .off
        }
    }

    /// Another language: every voice starts again in it. Nil follows the Mac.
    func setLanguage(_ identifier: String?) {
        guard identifier != preferences.captionLanguage else { return }
        preferences.captionLanguage = identifier
        guard isOn else { return }
        for id in Array(listeners.keys) { stopListening(to: id) }
        model = nil
        log.clear()
        prepare()
    }

    /// A language's own name for itself — "Dansk", "English" — as language menus show them.
    static func name(of locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        let name = locale.localizedString(forLanguageCode: code) ?? locale.identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Getting the model ready

    private var wantedLocale: Locale {
        preferences.captionLanguage.map(Locale.init(identifier:)) ?? Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }

    private func prepare() {
        preparing?.cancel()
        let wanted = wantedLocale
        status = .preparing(String(localized: "Getting captions ready…"))
        preparing = Task { [weak self] in
            guard let found = await CaptionModel.find(for: wanted) else {
                self?.status = .problem(String(localized: "Live Captions aren’t available in \(Self.name(of: wanted)).", comment: "%@ is a language, e.g. Dansk"))
                self?.preparing = nil
                return
            }
            let name = Self.name(of: found.locale)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [found.makeModule()]) {
                    // macOS fetches the model once; say how far along it is.
                    let progress = request.progress
                    let watcher = Task { [weak self] in
                        while !Task.isCancelled {
                            let percent = Int(progress.fractionCompleted * 100)
                            self?.status = .preparing(String(localized: "Downloading \(name) for captions… \(percent) %", comment: "%@ is a language, e.g. Dansk; then how far along the download is, in percent"))
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    defer { watcher.cancel() }
                    try await request.downloadAndInstall()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.sync.warning("Captions: the \(found.locale.identifier) model couldn’t be installed — \(error.localizedDescription)")
                self.status = .problem(String(localized: "Live Captions couldn’t get \(name) ready.", comment: "%@ is a language, e.g. Dansk"))
                self.preparing = nil
                return
            }
            guard let self, !Task.isCancelled, self.isOn else { return }
            Log.sync.notice("Captions: on, \(found.locale.identifier) with the \(found.kind == .general ? "general" : "dictation") model")
            self.model = found
            self.language = found.locale
            self.status = .on
            self.preparing = nil
            for id in self.voices.keys { self.listen(to: id) }
        }
    }

    private func findChoices() async {
        var found: [Locale] = []
        var wanted = Locale.preferredLanguages.map(Locale.init(identifier:))
        if let chosen = preferences.captionLanguage { wanted.insert(Locale(identifier: chosen), at: 0) }
        for locale in wanted {
            guard let model = await CaptionModel.find(for: locale),
                  !found.contains(where: { $0.identifier == model.locale.identifier })
            else { continue }
            found.append(model.locale)
        }
        choices = found
    }

    // MARK: - Listening

    private func listen(to id: String) {
        guard let model, let voice = voices[id], listeners[id] == nil else { return }
        let listener = VoiceListener(
            model: model,
            onResult: { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal, from: id) },
            onFailure: { [weak self] message in self?.failed(message, voice: id) }
        )
        listeners[id] = listener
        switch voice.source {
        case .microphone(let tap):
            tap.feed = listener.feed
        case .track(let track):
            let tap = TrackTap(feed: listener.feed)
            track.add(tap)
            trackTaps[id] = tap
        }
    }

    private func stopListening(to id: String) {
        if let voice = voices[id] {
            switch voice.source {
            case .microphone(let tap):
                tap.feed = nil
            case .track(let track):
                if let tap = trackTaps.removeValue(forKey: id) { track.remove(tap) }
            }
        }
        listeners.removeValue(forKey: id)?.stop()
        log.close(speakerID: id)
    }

    private func heard(_ text: String, isFinal: Bool, from id: String) {
        guard let voice = voices[id], listeners[id] != nil else { return }
        log.receive(text, isFinal: isFinal, from: id, named: voice.name)
    }

    private func failed(_ message: String, voice id: String) {
        // What was said is never logged; only that the model gave up.
        Log.sync.warning("Captions: a voice’s model stopped — \(message)")
        stopListening(to: id)
        status = .problem(String(localized: "Live Captions stopped working. Turn them off and on to try again."))
    }
}

/// Which of Apple's speech models captions a language, and in which of its locales: the
/// general one where it knows the language — it punctuates, and is the better of the two —
/// and the dictation one otherwise, which is the one that has Danish.
struct CaptionModel: Sendable, Equatable {
    enum Kind: Sendable { case general, dictation }

    let kind: Kind
    let locale: Locale

    static func find(for locale: Locale) async -> CaptionModel? {
        var candidates = [locale]
        // "en-DK" — English on a Danish Mac — has no model of its own; English does.
        if let language = locale.language.languageCode?.identifier { candidates.append(Locale(identifier: language)) }
        for candidate in candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return CaptionModel(kind: .general, locale: supported)
            }
        }
        for candidate in candidates {
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: candidate) {
                return CaptionModel(kind: .dictation, locale: supported)
            }
        }
        return nil
    }

    /// A model of this kind, set up for live speech: it reports words while it is still
    /// hearing them, and settles on them often.
    func makeModule() -> any SpeechModule {
        switch kind {
        case .general:
            SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }
    }
}

/// One voice, captioned: its audio goes in on WebRTC's audio threads; the words come out on
/// the main actor, as the model hears them.
final class VoiceListener: Sendable {
    /// Takes the next bit of audio. Safe from any thread.
    let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private let finish: @Sendable () -> Void
    private let task: Task<Void, Never>

    init(model: CaptionModel,
         onResult: @escaping @MainActor @Sendable (String, Bool) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        // A couple of seconds of audio at most: if the model falls behind, the oldest goes.
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(200))
        feed = { continuation.yield(AudioChunk(buffer: $0)) }
        finish = { continuation.finish() }
        task = Task.detached(priority: .userInitiated) {
            do {
                try await Self.run(model: model, audio: audio, onResult: onResult)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                await onFailure(error.localizedDescription)
            }
        }
    }

    /// No more audio, and nothing more from the model.
    func stop() {
        finish()
        task.cancel()
    }

    private static func run(model: CaptionModel, audio: AsyncStream<AudioChunk>,
                            onResult: @escaping @MainActor @Sendable (String, Bool) -> Void) async throws {
        let module = model.makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CaptionError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, inputFeed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        let reading = Task { try await read(module, onResult: onResult) }

        var reformatter = AudioReformatter(target: format)
        for await chunk in audio {
            if let converted = reformatter.convert(chunk.buffer) {
                inputFeed.yield(AnalyzerInput(buffer: converted))
            }
        }
        inputFeed.finish()
        reading.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func read(_ module: any SpeechModule, onResult: @escaping @MainActor @Sendable (String, Bool) -> Void) async throws {
        if let general = module as? SpeechTranscriber {
            for try await result in general.results {
                await onResult(String(result.text.characters), result.isFinal)
            }
        } else if let dictation = module as? DictationTranscriber {
            for try await result in dictation.results {
                await onResult(String(result.text.characters), result.isFinal)
            }
        }
    }
}

private enum CaptionError: LocalizedError {
    case noAudioFormat

    var errorDescription: String? { String(localized: "The speech model takes no audio this Mac can give it.") }
}

/// A buffer handed from WebRTC's audio thread to the model's task, which is its only user
/// from then on.
private struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Turns audio as WebRTC has it into what the model takes. The converter keeps its state from
/// one bit to the next, as a stream's has to; audio in another format gets a new one.
private struct AudioReformatter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// This Mac's microphone as WebRTC sends it, after its own processing — for captions. Set up
/// with the call's audio, and silent until captions listen and while you're muted.
final class MicrophoneTap: NSObject, LKRTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _feed: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _isMuted = false

    var feed: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _feed } }
        set { lock.withLock { _feed = newValue } }
    }

    /// What you say muted isn't written out, even on this Mac.
    var isMuted: Bool {
        get { lock.withLock { _isMuted } }
        set { lock.withLock { _isMuted = newValue } }
    }

    /// For the log: whether WebRTC hands the microphone over at all, and how loud — once, a
    /// few seconds into listening.
    private var heardBuffers = 0
    private var loudest: Float = 0

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        Log.sync.notice("Captions: WebRTC's microphone processing started, \(sampleRateHz) Hz, \(channels) channel(s)")
    }

    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let (feed, isMuted) = lock.withLock { (_feed, _isMuted) }
        guard let feed, !isMuted, let buffer = audioBuffer.monoPCMBuffer() else { return }
        note(buffer)
        feed(buffer)
    }

    /// Five seconds of microphone, then one line saying how loud it was: a level near zero
    /// while talking means the samples are scaled wrong.
    private func note(_ buffer: AVAudioPCMBuffer) {
        guard heardBuffers <= 500, let samples = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buffer.frameLength))
        loudest = max(loudest, peak)
        heardBuffers += 1
        if heardBuffers == 500 {
            Log.sync.notice("Captions: hearing this Mac's microphone, \(Int(buffer.format.sampleRate)) Hz, loudest \(String(format: "%.4f", self.loudest)) in 5 s")
        }
    }

    func audioProcessingRelease() {}
}

/// Someone else's voice, as WebRTC plays it.
final class TrackTap: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    private let feed: @Sendable (AVAudioPCMBuffer) -> Void

    init(feed: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.feed = feed
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        // WebRTC's buffer is only lent for the call; the model reads it later.
        if let copy = pcmBuffer.copied() { feed(copy) }
    }
}

private extension LKRTCAudioBuffer {
    /// The first channel, as floats from -1 to 1. WebRTC keeps its processing audio as floats
    /// on a 16-bit scale, ten milliseconds at a time — which gives the sample rate.
    func monoPCMBuffer() -> AVAudioPCMBuffer? {
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(frames * 100), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData?[0]
        else { return nil }
        var scale = Float(1) / 32768
        vDSP_vsmul(rawBuffer(forChannel: 0), 1, &scale, output, 1, vDSP_Length(frames))
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

private extension AVAudioPCMBuffer {
    func copied() -> AVAudioPCMBuffer? {
        guard frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let from = from.mData, let to = to.mData else { return nil }
            memcpy(to, from, Int(frameLength) * bytesPerFrame)
        }
        return copy
    }
}
