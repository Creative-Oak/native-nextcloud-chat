import AVFoundation
import Observation

/// Records a voice message from the composer, lets it be listened back to, and sends it.
///
/// `AVAudioRecorder` only writes to a file, so the recording lives in the app's temporary
/// folder for as long as it takes to decide — and is deleted the moment it is sent or thrown
/// away. Anything a crash left behind is swept up the next time a recorder is made.
@MainActor
@Observable
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        /// Stopped, waiting to be sent or thrown away.
        case recorded
        case sending
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Seconds recorded — counting while recording, the length once stopped.
    private(set) var elapsed: TimeInterval = 0
    /// Loudness, 0…1, twenty times a second for the whole recording — the bars are drawn
    /// from this at whatever width there is room for.
    private(set) var samples: [Float] = []
    private(set) var isPreviewing = false
    private(set) var previewPosition: TimeInterval = 0

    @ObservationIgnored private let session: Session
    @ObservationIgnored private let token: String
    @ObservationIgnored private let conversationName: String
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var preview: AVAudioPlayer?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    /// Anything shorter is a click on the button, not a message.
    private static let minimumLength: TimeInterval = 0.7
    private static let filePrefix = "kvidr-voice-"

    init(session: Session, token: String, conversationName: String) {
        self.session = session
        self.token = token
        self.conversationName = conversationName
        Self.sweepLeftovers()
    }

    var canRecord: Bool {
        session.capabilitySnapshot.attachmentsAllowed
    }

    func start() async {
        guard phase == .idle || phase.isFailure else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed(String(localized: "kvidr isn’t allowed to use the microphone. You can allow it in System Settings ▸ Privacy & Security ▸ Microphone.", comment: "Recording a voice message without microphone permission; use the System Settings names of this language"))
            return
        }

        // WAV, not AAC: Talk only keeps a share marked as a voice message when the file is
        // `audio/wav` or `audio/mpeg` (`fixMimeTypeOfVoiceMessage`), and anything else arrives
        // as a plain file. macOS has no MP3 encoder. Mono 16-bit at 16 kHz — the rate the
        // speech models transcribe at, and plenty for a voice — is about 1.9 MB a minute.
        let url = FileManager.default.temporaryDirectory
            .appending(path: Self.filePrefix + UUID().uuidString + ".wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                phase = .failed(String(localized: "The recording couldn’t start.", comment: "Voice message recording failed"))
                return
            }
            self.recorder = recorder
            fileURL = url
            samples = []
            elapsed = 0
            phase = .recording
            startMetering()
        } catch {
            phase = .failed(String(localized: "The recording couldn’t start.", comment: "Voice message recording failed"))
        }
    }

    /// Stops recording and keeps it for listening back. A recording too short to be one is
    /// thrown away instead.
    func stop() {
        guard phase == .recording, let recorder else { return }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        meter?.cancel()
        guard length >= Self.minimumLength else {
            discard()
            return
        }
        elapsed = length
        phase = .recorded
    }

    /// Throws the recording away, whatever state it is in.
    func discard() {
        recorder?.stop()
        recorder = nil
        preview?.stop()
        preview = nil
        isPreviewing = false
        meter?.cancel()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        samples = []
        elapsed = 0
        previewPosition = 0
        phase = .idle
    }

    func togglePreview() {
        guard phase == .recorded, let fileURL else { return }
        if let preview, preview.isPlaying {
            preview.pause()
            isPreviewing = false
            meter?.cancel()
            return
        }
        if preview == nil {
            preview = try? AVAudioPlayer(contentsOf: fileURL)
        }
        guard let preview else { return }
        if preview.currentTime >= preview.duration - 0.05 { preview.currentTime = 0 }
        preview.play()
        isPreviewing = true
        startPreviewTicking()
    }

    var previewProgress: Double {
        elapsed > 0 ? min(previewPosition / elapsed, 1) : 0
    }

    /// Stops a recording still going, then uploads it and shares it into the conversation as
    /// a voice message.
    func send(replyTo: Int?, threadID: Int? = nil) {
        if phase == .recording { stop() }
        guard phase == .recorded, let fileURL else { return }
        preview?.stop()
        preview = nil
        isPreviewing = false
        phase = .sending

        let session = self.session
        let token = self.token
        let name = Self.fileName(conversation: conversationName)
        Task { [weak self] in
            // Read into memory and the file removed straight away: the upload doesn't need
            // it, and a voice message shouldn't sit in a temporary folder while it goes up.
            guard let data = try? Data(contentsOf: fileURL) else {
                self?.phase = .failed(String(localized: "The recording couldn’t be read.", comment: "Voice message recording failed"))
                return
            }
            try? FileManager.default.removeItem(at: fileURL)
            self?.fileURL = nil

            let folder = session.capabilitySnapshot.config.attachmentsFolder ?? AttachmentService.defaultFolder
            do throws(TalkError) {
                let path = try await session.attachments.upload(data, fileName: name, folder: folder, progress: { _ in })
                try await session.attachments.share(path: path, token: token, replyTo: replyTo, isVoiceMessage: true, threadID: threadID)
                self?.samples = []
                self?.elapsed = 0
                self?.phase = .idle
            } catch {
                self?.phase = .failed(String(localized: "The voice message wasn’t sent: \(error.userMessage)", comment: "%@ is the reason"))
            }
        }
    }

    // MARK: - Private

    private func startMetering() {
        meter?.cancel()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // Decibels, -160…0, where speech sits roughly between -50 and -10.
                let power = recorder.averagePower(forChannel: 0)
                let level = max(0.08, min(1, (power + 50) / 40))
                self.samples.append(level)
                self.elapsed = recorder.currentTime
            }
        }
    }

    private func startPreviewTicking() {
        meter?.cancel()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let preview = self.preview else { return }
                self.previewPosition = preview.currentTime
                if !preview.isPlaying {
                    self.isPreviewing = false
                    self.previewPosition = 0
                    return
                }
            }
        }
    }

    /// The loudest of each stretch, so a short word still shows as a peak.
    static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty, count > 0 else { return Array(repeating: 0.08, count: max(count, 0)) }
        return (0..<count).map { index in
            let start = index * values.count / count
            let end = max(start + 1, (index + 1) * values.count / count)
            return values[min(start, values.count - 1)..<min(end, values.count)].max() ?? 0.08
        }
    }

    /// The name Talk's own web app gives a recording, in the user's language, so it reads the
    /// same in Files.
    private static func fileName(conversation: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let safe = conversation.replacingOccurrences(of: "/", with: "-")
        let name = String(
            localized: "Talk recording from \(formatter.string(from: now)) (\(safe))",
            comment: "File name of a voice message, as Talk's web app names it. %1$@ is the date and time, %2$@ the conversation"
        )
        return name + ".wav"
    }

    private static func sweepLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items where item.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: item))
        }
    }
}

extension VoiceRecorder.Phase {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
