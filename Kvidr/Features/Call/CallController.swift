import AVFoundation
import CoreAudio
import Foundation
@preconcurrency import LiveKitWebRTC

/// A call this Mac is in: joining it on Nextcloud, sending the microphone to the media server,
/// and receiving everyone else who sends something. Audio only for now.
///
/// Everything goes through the High Performance Backend's media server, even with one other
/// person: this client sends its own media once, as an offer to its own session, and asks
/// each other publisher's session for an offer of theirs. See ``CallSignal``.
@MainActor
@Observable
final class CallController {
    enum Phase: Equatable {
        case joining
        case inCall
        case ended(reason: String?)
    }

    struct Participant: Identifiable, Equatable {
        /// Their signaling session.
        let id: String
        var userID: String?
        var actorType: String?
        var actorID: String?
        var name: String
        /// Their audio has reached this Mac.
        var isConnected = false
        var isAudioOn = true
        var isVideoOn = false
        /// Their voice is coming through right now.
        var isSpeaking = false
        /// Their hand is up, since when — whoever raised theirs first comes first.
        var handRaisedAt: Date?
        var isHandRaised: Bool { handRaisedAt != nil }
        /// Their camera, once it has arrived.
        var video: VideoTrack?
        /// Their screen, while they share it.
        var screen: VideoTrack?

        /// Who they are, for their picture.
        var actor: MessageActor {
            MessageActor(type: actorType ?? "users", id: actorID ?? userID ?? "", displayName: name)
        }
    }

    let token: String
    let conversation: Conversation
    private(set) var phase: Phase = .joining

    var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }
    private(set) var participants: [Participant] = []
    /// Whoever started talking last — who a small view of a group call shows.
    private(set) var recentSpeakerID: String?
    /// This Mac's hand is up.
    private(set) var isHandRaised = false

    /// An emoji someone sent, floating up over the call for a few seconds.
    struct Reaction: Identifiable, Equatable {
        let id = UUID()
        let emoji: String
        let name: String
    }

    private(set) var reactions: [Reaction] = []
    /// The emoji on offer — the server's list.
    var reactionChoices: [String] { session.capabilitySnapshot.config.effectiveCallReactions }
    /// Moderators can mute others, as in Talk's apps.
    var canMuteOthers: Bool { conversation.isModerator }
    private(set) var isMuted = false
    /// This Mac's own microphone has someone talking into it — the ring around your tile.
    private(set) var isSpeaking = false
    private(set) var isCameraOn = false
    /// This Mac's camera, to show in the corner.
    private(set) var localVideo: VideoTrack?
    /// The cameras to choose from, and the one in use.
    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var cameraID: String?
    /// Why the camera didn't come on, until the next try.
    private(set) var cameraProblem: String?
    /// This Mac's screen is going out to the call.
    private(set) var isSharingScreen = false {
        didSet { if isSharingScreen != oldValue { onScreenSharingChanged(isSharingScreen) } }
    }
    /// What this Mac is sharing, to show it back while kvidr is in front.
    private(set) var localScreen: VideoTrack?
    /// Set by the app: sharing started or stopped — the window steps aside for the mini call.
    @ObservationIgnored var onScreenSharingChanged: (Bool) -> Void = { _ in }

    /// Someone else's shared screen, when there is one — the first, if more than one share.
    var sharedScreen: (participant: Participant, screen: VideoTrack)? {
        for participant in participants {
            if let screen = participant.screen { return (participant, screen) }
        }
        return nil
    }
    /// When this Mac's own connection came up.
    private(set) var connectedAt: Date?

    /// Someone came or went, said on the stage for a few seconds.
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    /// In a group call: who just joined or left. A one-to-one says it by itself — the call
    /// is answered, or over.
    private(set) var notice: Notice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Comings and goings count as news from here on: the people already in the call when this
    /// Mac joined — or rejoined, for another microphone — aren't.
    @ObservationIgnored private var announcesFrom: Date?
    /// When the first other person's media reached this Mac — the call "answered", which is
    /// where its timer starts, as a phone's does.
    private(set) var answeredAt: Date?

    @ObservationIgnored private let session: Session
    @ObservationIgnored private let ownSessionID: String
    @ObservationIgnored private let iceServers: [IceServerConfig]
    @ObservationIgnored private let nick: String
    @ObservationIgnored private let nameForSession: (String) -> String?
    @ObservationIgnored private var roster: CallRoster
    @ObservationIgnored private var publisher: CallPeer?
    /// Keyed by session, and by "session#screen" for someone's shared screen.
    @ObservationIgnored private var subscribers: [String: CallPeer] = [:]
    @ObservationIgnored private var screenPublisher: CallPeer?
    @ObservationIgnored private var screenShare: ScreenShare?
    @ObservationIgnored private var screenTrack: LKRTCVideoTrack?
    @ObservationIgnored private var audioTrack: LKRTCAudioTrack?
    @ObservationIgnored private var videoTrack: LKRTCVideoTrack?
    @ObservationIgnored private var capturer: LKRTCCameraVideoCapturer?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Reads how loud everyone is, a few times a second: the ring around whoever is talking.
    @ObservationIgnored private var levelsTask: Task<Void, Never>?
    @ObservationIgnored private var ownSpeaking = SpeakingDetector()
    @ObservationIgnored private var speaking: [String: SpeakingDetector] = [:]
    /// Sessions whose loudness this Mac can measure for itself; for anyone else, what they
    /// say on the data channel has to do. See ``received(_:from:)``.
    @ObservationIgnored private var measured: Set<String> = []
    /// The state being said again, per session — "" for everyone. See ``repeatState(to:)``.
    @ObservationIgnored private var stateRepeats: [String: Task<Void, Never>] = [:]
    /// People to ask for their media once this Mac is in the call — see ``requestOffer(from:)``.
    @ObservationIgnored private var heldOfferRequests: Set<String> = []
    /// Made afresh for each start of the call's media: its audio opens the Mac's default
    /// microphone and speaker then, and keeps them.
    @ObservationIgnored private var factory: LKRTCPeerConnectionFactory
    /// The microphones and speakers to choose from.
    let audioDevices = AudioDevices()
    /// What everyone says, written out — when they're on.
    let captions: LiveCaptions
    /// Notes on the call, from the captions' transcript: written when it ends, or asked for.
    let summary = CallSummary()
    /// The microphone as WebRTC sends it, for captions. Part of the audio from the start;
    /// silent until captions listen.
    @ObservationIgnored private let microphoneTap: MicrophoneTap

    private static let sslReady: Void = { LKRTCInitializeSSL() }()

    /// The Mac's own audio device handling, as WebRTC has it; the microphone passes the tap
    /// on its way out, after echo cancellation and noise suppression.
    private static func makeFactory(microphone: MicrophoneTap) -> LKRTCPeerConnectionFactory {
        _ = sslReady
        // Spelled out rather than left to defaults: with a processing module of our own, what's
        // switched on is ours to say. The same as WebRTC's own defaults for a call — echo
        // cancelling, noise suppression, the rumble filter and automatic gain.
        let config = LKRTCAudioProcessingConfig()
        config.isEchoCancellationEnabled = true
        config.isNoiseSuppressionEnabled = true
        config.isHighpassFilterEnabled = true
        config.isAutoGainControl1Enabled = true
        let processing = LKRTCDefaultAudioProcessingModule(config: config, capturePostProcessingDelegate: microphone, renderPreProcessingDelegate: nil)
        return LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioProcessingModule: processing
        )
    }

    init(session: Session, conversation: Conversation, ownSessionID: String, iceServers: [IceServerConfig],
         nick: String, captions: LiveCaptions, nameForSession: @escaping (String) -> String?) {
        self.session = session
        self.conversation = conversation
        self.token = conversation.token
        self.ownSessionID = ownSessionID
        self.iceServers = iceServers
        self.nick = nick
        self.nameForSession = nameForSession
        self.roster = CallRoster(ownSessionID: ownSessionID)
        self.captions = captions
        let microphone = MicrophoneTap()
        self.microphoneTap = microphone
        self.factory = Self.makeFactory(microphone: microphone)
    }

    // MARK: - Joining and leaving

    /// Joins — starting the call if nobody is in it — and starts sending the microphone.
    func join() async {
        // Left meanwhile — say, while the audio was restarting: don't walk back in.
        guard phase == .joining else { return }
        Log.sync.notice("Call: joining")
        captions.begin()
        do throws(TalkError) {
            // With video: the camera's track goes out from the start, off.
            try await session.calls.join(token: token, flags: [.inCall, .withAudio, .withVideo])
        } catch {
            end(reason: "Couldn’t join the call: \(error.userMessage)")
            return
        }
        guard phase == .joining else { return }
        await publish()
    }

    /// Couldn't even begin.
    func fail(_ reason: String) {
        end(reason: reason)
    }

    /// Whether hanging up ends the call for everyone, as Talk's apps do in a one-to-one: with
    /// only two people in it, one hanging up is the call over.
    var hangUpEndsCall: Bool { conversation.isOneToOne }

    /// Whether the other way of hanging up is offered: leaving a one-to-one's call without
    /// ending it, or, for a moderator, ending a group's for everyone.
    var canHangUpTheOtherWay: Bool { conversation.isOneToOne || conversation.isModerator }

    /// Hangs up the usual way; see ``hangUpEndsCall``.
    func hangUp() {
        leave(everyone: hangUpEndsCall)
    }

    func hangUpTheOtherWay() {
        leave(everyone: !hangUpEndsCall)
    }

    func leave(everyone: Bool = false) {
        guard !isEnded else { return }
        tearDown()
        phase = .ended(reason: nil)
        summarizeIfCaptioned()
        let calls = session.calls
        let token = self.token
        Task {
            do throws(TalkError) {
                try await calls.leave(token: token, everyone: everyone)
                Log.sync.notice("Call: left")
            } catch {
                Log.sync.warning("Call: leaving failed — \(error.userMessage)")
            }
        }
    }

    /// Uses another microphone: it becomes the Mac's default, and the call's audio starts again.
    func useMicrophone(_ id: AudioObjectID) {
        guard id != audioDevices.defaultInput else { return }
        audioDevices.setDefaultInput(id)
        Task { await restartAudio() }
    }

    func useSpeaker(_ id: AudioObjectID) {
        guard id != audioDevices.defaultOutput else { return }
        audioDevices.setDefaultOutput(id)
        Task { await restartAudio() }
    }

    /// WebRTC's audio holds on to the devices it started with, and the media server holds on
    /// to what this session publishes: so out of the call and straight back in, with new
    /// connections that open the new devices. The others hear a moment's gap.
    private func restartAudio() async {
        guard !isEnded else { return }
        Log.sync.notice("Call: restarting audio for another device")
        tearDown()
        roster = CallRoster(ownSessionID: ownSessionID)
        factory = Self.makeFactory(microphone: microphoneTap)
        phase = .joining
        try? await session.calls.leave(token: token)
        await join()
    }

    func toggleMute() {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
        microphoneTap.isMuted = isMuted
        if isMuted {
            ownSpeaking.silence()
            setOwnSpeaking(false)
        }
        broadcast(isMuted ? .audioOff : .audioOn)
    }

    /// Turns the camera on or off. The camera goes out from the start of the call whenever
    /// the Mac has one, just switched off — so turning it on needs no new connection.
    func toggleCamera() {
        if isCameraOn {
            stopCamera()
        } else {
            Task { await startCamera() }
        }
    }

    func useCamera(_ id: String) {
        guard id != cameraID else { return }
        cameraID = id
        if isCameraOn {
            capturer?.stopCapture()
            Task { await startCamera() }
        }
    }

    private func startCamera() async {
        guard let capturer, let videoTrack else { return }
        cameraProblem = nil
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraProblem = "kvidr isn’t allowed to use the camera. Turn it on in System Settings → Privacy & Security → Camera."
            return
        }
        cameras = Self.findCameras()
        guard let device = cameras.first(where: { $0.uniqueID == cameraID }) ?? cameras.first else {
            cameraProblem = "No camera found. Connect one, or use your iPhone as a camera with Continuity Camera."
            return
        }
        cameraID = device.uniqueID
        let format = Self.format(for: device)
        let fps = format.map { Int(min(30, $0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)) } ?? 30
        guard let format else { return }
        do {
            try await capturer.startCapture(with: device, format: format, fps: fps)
        } catch {
            Log.sync.warning("Couldn’t start the camera: \(error.localizedDescription)")
            cameraProblem = "The camera couldn’t be started."
            return
        }
        videoTrack.isEnabled = true
        isCameraOn = true
        broadcast(.videoOn)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.sync.notice("Call: camera started, \(device.localizedName) \(dims.width)x\(dims.height) @\(fps)")
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isCameraOn, let publisher = self.publisher else { return }
                let summary = await publisher.sentVideoSummary()
                Log.sync.notice("Call: video out — \(summary)")
            }
        }
    }

    private func stopCamera() {
        capturer?.stopCapture()
        videoTrack?.isEnabled = false
        isCameraOn = false
        broadcast(.videoOff)
    }

    /// Every camera the Mac can use: built in, plugged in, or an iPhone through Continuity
    /// Camera. WebRTC's own list leaves the last two out.
    static func findCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Up to 720p: plenty for a call, and what the media server passes on without strain.
    private static func format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        func width(_ format: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(format.formatDescription).width }
        return formats.filter { width($0) <= 1280 }.max { width($0) < width($1) } ?? formats.first
    }

    /// Tells everyone: on the data channel, which the media server passes to everyone
    /// receiving this Mac, and to each session through the signaling server.
    private func broadcast(_ status: MediaStatus) {
        publisher?.send(status)
        if status.signalingData(to: "") != nil {
            for id in roster.inCall.keys {
                Task { await self.session.signaling.send(.mediaStatus(toSession: id, status)) }
            }
        }
        repeatState(to: nil)
    }

    /// Someone new hears where things stand — a hand that's up included.
    private func tellCurrentState(to id: String) {
        repeatState(to: id)
        if isHandRaised {
            Task { await self.session.signaling.send(.callMessage(toSession: id, .raiseHand(true, at: Date()))) }
        }
    }

    /// The state again, now and after 1, 2, 4, 8 and 16 seconds — as Talk's web app sends it.
    /// A message can arrive before the other side is ready for it (its data channel not open
    /// yet, its connection to this Mac not made), and one that is lost like that would leave
    /// them showing a camera as off that is on. Nil: to everyone, after a change here.
    private func repeatState(to id: String?) {
        let key = id ?? ""
        stateRepeats[key]?.cancel()
        stateRepeats[key] = Task { [weak self] in
            var delay: Duration = .zero
            while !Task.isCancelled {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard let self, !Task.isCancelled, !self.isEnded else { return }
                let state: [MediaStatus] = [self.isMuted ? .audioOff : .audioOn, self.isCameraOn ? .videoOn : .videoOff]
                let targets = id.map { [$0] } ?? Array(self.roster.inCall.keys)
                for status in state {
                    // On the data channel for a newcomer's repeats too, though it reaches
                    // everyone: Talk for iOS only listens there — a mute or unmute through
                    // signaling it ignores — so a camera turned on before the phone had
                    // joined stayed dark on it until turned off and on again.
                    self.publisher?.send(status)
                    for target in targets {
                        await self.session.signaling.send(.mediaStatus(toSession: target, status))
                    }
                }
                delay = delay == .zero ? .seconds(1) : delay * 2
                if delay > .seconds(16) { return }
            }
        }
    }

    func received(_ status: MediaStatus, from sessionID: String) {
        guard let index = participants.firstIndex(where: { $0.id == sessionID }) else { return }
        switch status {
        case .audioOn: participants[index].isAudioOn = true
        case .audioOff: participants[index].isAudioOn = false
        case .videoOn: participants[index].isVideoOn = true
        case .videoOff: participants[index].isVideoOn = false
        // Talk's own clients say this too; it's only needed for a stream WebRTC reports
        // no level for, since a measured one is quicker and doesn't depend on them.
        case .speaking where !measured.contains(sessionID):
            participants[index].isSpeaking = true
            recentSpeakerID = sessionID
        case .stoppedSpeaking where !measured.contains(sessionID): participants[index].isSpeaking = false
        case .speaking, .stoppedSpeaking: break
        }
    }

    // MARK: - Who is talking

    /// Every quarter second, how loud this Mac's microphone is and how loud each voice coming
    /// in is — WebRTC's own measurements, which need nothing of the other clients.
    private func watchLevels() {
        levelsTask?.cancel()
        levelsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, !self.isEnded else { return }
                await self.readLevels()
            }
        }
    }

    private func readLevels() async {
        let now = Date()
        if let publisher, !isMuted, let level = await publisher.audioLevel(sending: true) {
            if measured.insert(ownSessionID).inserted {
                Log.sync.notice("Call: hearing this Mac's own level")
            }
            if ownSpeaking.update(level: level, at: now) { setOwnSpeaking(ownSpeaking.isSpeaking) }
        }
        for id in participants.map(\.id) {
            guard let peer = subscribers[id], let level = await peer.audioLevel(sending: false) else { continue }
            if measured.insert(id).inserted {
                Log.sync.notice("Call: hearing levels from \(id.prefix(6))")
            }
            var detector = speaking[id] ?? SpeakingDetector()
            let changed = detector.update(level: level, at: now)
            speaking[id] = detector
            guard changed, let index = participants.firstIndex(where: { $0.id == id }) else { continue }
            participants[index].isSpeaking = detector.isSpeaking
            if detector.isSpeaking { recentSpeakerID = id }
        }
    }

    /// Tells the others, so their own ring around this Mac's tile comes on — Talk's clients
    /// listen for this on the data channel.
    private func setOwnSpeaking(_ talking: Bool) {
        guard isSpeaking != talking else { return }
        isSpeaking = talking
        publisher?.send(talking ? .speaking : .stoppedSpeaking)
    }

    // MARK: - Hands, reactions, and a moderator's mute

    /// Up, or down again.
    func toggleHand() {
        isHandRaised.toggle()
        sendToEveryone(.raiseHand(isHandRaised, at: Date()))
    }

    /// Sends an emoji to everyone — and shows it here too, as nobody sends one back.
    func react(_ emoji: String) {
        sendToEveryone(.reaction(emoji))
        show(Reaction(emoji: emoji, name: "You"))
    }

    /// A moderator mutes someone. Everyone in the call hears it; they mute themselves.
    func forceMute(_ participantID: String) {
        guard canMuteOthers else { return }
        Log.sync.notice("Call: muting \(participantID.prefix(6)), told to \(self.roster.inCall.count) session(s)")
        sendToEveryone(.forceMute(target: participantID))
        if let index = participants.firstIndex(where: { $0.id == participantID }) {
            participants[index].isAudioOn = false
            participants[index].isSpeaking = false
        }
    }

    func receivedHand(_ isRaised: Bool, from sessionID: String) {
        guard let index = participants.firstIndex(where: { $0.id == sessionID }) else { return }
        let was = participants[index].isHandRaised
        participants[index].handRaisedAt = isRaised ? (participants[index].handRaisedAt ?? Date()) : nil
        if isRaised, !was { show("\(participants[index].name) raised their hand", symbol: "hand.raised.fill") }
    }

    func receivedReaction(_ emoji: String, from sessionID: String) {
        guard let participant = participants.first(where: { $0.id == sessionID }) else { return }
        show(Reaction(emoji: emoji, name: participant.name))
    }

    /// A moderator muted someone — maybe this Mac.
    func receivedForceMute(target: String) {
        if target == ownSessionID {
            guard !isMuted else { return }
            toggleMute()
            show("A moderator muted you", symbol: "mic.slash.fill")
        } else if let index = participants.firstIndex(where: { $0.id == target }) {
            participants[index].isAudioOn = false
            participants[index].isSpeaking = false
        }
    }

    private func show(_ reaction: Reaction) {
        reactions.append(reaction)
        // A flood of them — a room full of applause — keeps only the latest few on screen.
        if reactions.count > 12 { reactions.removeFirst(reactions.count - 12) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.reactions.removeAll { $0.id == reaction.id }
        }
    }

    /// To each session in the call — how Talk's clients send what isn't media.
    private func sendToEveryone(_ message: CallMessage) {
        for id in roster.inCall.keys {
            Task { await self.session.signaling.send(.callMessage(toSession: id, message)) }
        }
    }

    // MARK: - From the signaling server

    func participantsChanged(_ users: [CallParticipantState], everyone: CallFlags?) {
        if let everyone, !everyone.contains(.inCall) {
            apply(roster.ended())
            end(reason: nil)
            return
        }
        apply(roster.apply(users))
    }

    func sessionsLeft(_ ids: [String]) {
        apply(roster.left(ids))
    }

    func handle(_ signal: CallSignal, from sender: String) {
        let isScreen = signal.roomType == "screen"
        switch signal.kind {
        case .answer(let sdp) where sender == ownSessionID:
            guard let peer = isScreen ? screenPublisher : publisher else { return }
            Task { try? await peer.setRemote(.answer, sdp: sdp) }
        case .offer(let sdp) where sender != ownSessionID:
            Task { await subscribe(to: sender, offer: sdp, sid: signal.sid ?? UUID().uuidString, roomType: signal.roomType) }
        case .candidate(let candidate):
            let peer = sender == ownSessionID
                ? (isScreen ? screenPublisher : publisher)
                : subscribers[Self.key(sender, signal.roomType)]
            peer?.add(candidate)
        case .unshareScreen:
            subscribers.removeValue(forKey: Self.key(sender, "screen"))?.close()
            if let index = participants.firstIndex(where: { $0.id == sender }) { participants[index].screen = nil }
        default:
            break
        }
    }

    private static func key(_ session: String, _ roomType: String) -> String {
        roomType == "screen" ? session + "#screen" : session
    }

    // MARK: - Sharing the screen

    /// Opens the system's picker; sharing starts once a window or display is chosen.
    func shareScreen() {
        guard !isEnded, screenShare == nil else { return }
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "screen")
        let share = ScreenShare(source: source)
        share.onStart = { [weak self] in
            guard let self else { return }
            self.localScreen = VideoTrack(track)
            self.isSharingScreen = true
            Task { await self.publishScreen(track) }
        }
        share.onStop = { [weak self] in self?.stopSharingScreen() }
        screenShare = share
        screenTrack = track
        share.pick()
    }

    func stopSharingScreen() {
        let wasPublishing = screenPublisher != nil
        screenShare?.stop()
        screenShare = nil
        screenPublisher?.close()
        screenPublisher = nil
        screenTrack = nil
        localScreen = nil
        isSharingScreen = false
        if wasPublishing, !isEnded {
            Task { await self.session.signaling.send(.roomCallSignal(CallSignal(kind: .unshareScreen, roomType: "screen"))) }
        }
    }

    private func publishScreen(_ track: LKRTCVideoTrack) async {
        let sid = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let peer = CallPeer(factory: factory, iceServers: iceServers, remoteSession: ownSessionID, sid: sid, roomType: "screen") else {
            stopSharingScreen()
            return
        }
        let options = LKRTCRtpTransceiverInit()
        options.direction = .sendOnly
        options.streamIds = [ownSessionID + "-screen"]
        peer.connection.addTransceiver(with: track, init: options)
        screenPublisher = peer
        wire(peer)
        var offered = false
        peer.onConnectionChange = { [weak self] connected, failed in
            guard let self else { return }
            Log.sync.notice("Call: screen connected=\(connected) failed=\(failed)")
            // Up at the media server: have it offer the screen to everyone in the call.
            if connected, !offered {
                offered = true
                for id in self.roster.inCall.keys { self.offerScreen(to: id) }
            }
            if failed { self.stopSharingScreen() }
        }
        do {
            let offer = try await peer.makeOffer()
            try await peer.setLocal(.offer, sdp: offer)
            await send(CallSignal(kind: .offer(sdp: offer), sid: sid, roomType: "screen"), to: ownSessionID)
        } catch {
            Log.sync.warning("Call: the screen couldn’t be offered — \(error.localizedDescription)")
            stopSharingScreen()
        }
    }

    /// The others can't know a screen is being shared, so the media server is asked to offer
    /// it to each of them.
    private func offerScreen(to id: String) {
        Task { await self.send(CallSignal(kind: .sendOffer, roomType: "screen"), to: id) }
    }

    /// The signaling connection went away: without it, the call can't go on.
    func signalingLost() {
        guard !isEnded else { return }
        end(reason: "The connection to the call was lost.")
        let calls = session.calls
        let token = self.token
        Task { try? await calls.leave(token: token) }
    }

    // MARK: - Media

    private func publish() async {
        let factory = factory
        let sid = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let peer = CallPeer(factory: factory, iceServers: iceServers, remoteSession: ownSessionID, sid: sid) else {
            end(reason: "The call couldn’t be set up on this Mac.")
            return
        }
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio")
        track.isEnabled = !isMuted
        let options = LKRTCRtpTransceiverInit()
        options.direction = .sendOnly
        options.streamIds = [ownSessionID]
        peer.connection.addTransceiver(with: track, init: options)
        audioTrack = track
        microphoneTap.isMuted = isMuted
        captions.addMicrophone(microphoneTap)

        // The camera's track, off until the camera is turned on — there from the start even
        // without a camera, so one plugged in later needs no new connection.
        cameras = Self.findCameras()
        do {
            let videoSource = factory.videoSource()
            let video = factory.videoTrack(with: videoSource, trackId: "video")
            video.isEnabled = isCameraOn
            let videoOptions = LKRTCRtpTransceiverInit()
            videoOptions.direction = .sendOnly
            videoOptions.streamIds = [ownSessionID]
            peer.connection.addTransceiver(with: video, init: videoOptions)
            videoTrack = video
            localVideo = VideoTrack(video)
            capturer = LKRTCCameraVideoCapturer(delegate: videoSource)
        }
        peer.openStatusChannel()
        publisher = peer
        wire(peer)
        watchLevels()
        peer.onConnectionChange = { [weak self] connected, failed in
            guard let self else { return }
            Log.sync.notice("Call: publisher connected=\(connected) failed=\(failed)")
            if connected, self.connectedAt == nil { self.connectedAt = Date() }
            if connected, self.announcesFrom == nil { self.announcesFrom = Date().addingTimeInterval(2) }
            if connected, self.phase == .joining {
                self.phase = .inCall
                self.releaseHeldOfferRequests()
            }
            if failed { self.end(reason: "Your audio couldn’t reach the call.") }
        }

        do {
            let offer = try await peer.makeOffer()
            try await peer.setLocal(.offer, sdp: offer)
            await send(CallSignal(kind: .offer(sdp: offer), sid: sid), to: ownSessionID)
            // Scheme and host only: TURN credentials never reach the log.
            let servers = self.iceServers.flatMap(\.urls).map { $0.split(separator: "?").first.map(String.init) ?? $0 }
            Log.sync.notice("Call: sent own offer, ICE servers: \(servers.joined(separator: ", "))")
        } catch {
            end(reason: "The call couldn’t be set up: \(error.localizedDescription)")
        }
    }

    private func subscribe(to sessionID: String, offer: String, sid: String, roomType: String = "video") async {
        let key = Self.key(sessionID, roomType)
        subscribers[key]?.close()
        guard !isEnded,
              let peer = CallPeer(factory: factory, iceServers: iceServers, remoteSession: sessionID, sid: sid, roomType: roomType)
        else { return }
        subscribers[key] = peer
        wire(peer)
        if roomType == "screen" {
            // Someone's screen: its own connection beside their camera's.
            peer.onRemoteVideo = { [weak self] track in
                guard let self, let index = self.participants.firstIndex(where: { $0.id == sessionID }) else { return }
                self.participants[index].screen = VideoTrack(track)
            }
            do {
                try await peer.setRemote(.offer, sdp: offer)
                let answer = try await peer.makeAnswer()
                try await peer.setLocal(.answer, sdp: answer)
                await send(CallSignal(kind: .answer(sdp: answer), sid: sid, roomType: roomType), to: sessionID)
            } catch {
                Log.sync.warning("Couldn’t receive a shared screen: \(error.localizedDescription)")
            }
            return
        }
        peer.onRemoteVideo = { [weak self] track in
            guard let self, let index = self.participants.firstIndex(where: { $0.id == sessionID }) else { return }
            self.participants[index].video = VideoTrack(track)
        }
        peer.onRemoteAudio = { [weak self] track in
            guard let self, let participant = self.participants.first(where: { $0.id == sessionID }) else { return }
            self.captions.add(track: track, id: sessionID, name: participant.name)
        }
        peer.onStatus = { [weak self] status in self?.received(status, from: sessionID) }
        peer.onConnectionChange = { [weak self] connected, failed in
            Log.sync.notice("Call: subscriber \(sessionID.prefix(6)) connected=\(connected) failed=\(failed)")
            guard let self, let index = self.participants.firstIndex(where: { $0.id == sessionID }) else { return }
            self.participants[index].isConnected = connected
            if connected, self.answeredAt == nil { self.answeredAt = Date() }
        }
        do {
            try await peer.setRemote(.offer, sdp: offer)
            let answer = try await peer.makeAnswer()
            try await peer.setLocal(.answer, sdp: answer)
            await send(CallSignal(kind: .answer(sdp: answer), sid: sid), to: sessionID)
            // The media server starts a subscriber on a low layer of someone sending several;
            // ask for as good as the tile deserves.
            await send(CallSignal(kind: .selectStream(substream: preferredLayer, temporal: 2), sid: sid), to: sessionID)
        } catch {
            Log.sync.warning("Couldn’t receive a participant’s media: \(error.localizedDescription)")
        }
    }

    /// Candidates this side finds go to whoever the connection is with.
    private func wire(_ peer: CallPeer) {
        peer.onCandidate = { [weak self, weak peer] candidate in
            guard let self, let peer else { return }
            Task { await self.send(CallSignal(kind: .candidate(candidate), sid: peer.sid, roomType: peer.roomType), to: peer.remoteSession) }
        }
    }

    private func apply(_ change: CallRoster.Change) {
        let leaving = participants.filter { change.toDrop.contains($0.id) }.map(\.name)
        if !leaving.isEmpty { announce(leaving, did: "left", symbol: "person.fill.xmark") }
        let arriving = change.toSubscribe
            .filter { user in !participants.contains { $0.id == user.sessionID } }
            .map { name(for: $0) }
        if !arriving.isEmpty { announce(arriving, did: "joined", symbol: "person.fill.checkmark") }
        for id in change.toDrop {
            subscribers.removeValue(forKey: id)?.close()
            subscribers.removeValue(forKey: Self.key(id, "screen"))?.close()
            speaking[id] = nil
            measured.remove(id)
            captions.remove(id: id)
        }
        participants.removeAll { change.toDrop.contains($0.id) }
        for user in change.toSubscribe {
            if !participants.contains(where: { $0.id == user.sessionID }) {
                participants.append(Participant(
                    id: user.sessionID,
                    userID: user.userID,
                    actorType: user.actorType,
                    actorID: user.actorID,
                    name: name(for: user),
                    // Until they say otherwise: what they joined with.
                    isVideoOn: user.flags.contains(.withVideo)
                ))
            }
            tellCurrentState(to: user.sessionID)
            // Joined while this Mac shares its screen: they need the offer too.
            if isSharingScreen, screenPublisher != nil { offerScreen(to: user.sessionID) }
            requestOffer(from: user.sessionID)
        }
    }

    /// Asks for someone's media — or, while this Mac is still getting into the call, holds the
    /// request until it's in. Switching the microphone or speaker leaves and rejoins, and the
    /// roster that arrived in between asked straight away: the server refused ("not allowed"),
    /// and once back in, the roster already had them, so nothing asked again — no sound
    /// from them after a device switch.
    private func requestOffer(from session: String) {
        guard phase == .inCall else {
            heldOfferRequests.insert(session)
            return
        }
        Log.sync.notice("Call: requesting offer from \(session.prefix(6))")
        Task { await self.send(CallSignal(kind: .requestOffer), to: session) }
    }

    private func releaseHeldOfferRequests() {
        let held = heldOfferRequests
        heldOfferRequests = []
        for session in held where participants.contains(where: { $0.id == session }) {
            requestOffer(from: session)
        }
    }

    /// "Anna joined", "Anna and Bo left", "3 people joined".
    private func announce(_ names: [String], did what: String, symbol: String) {
        guard !conversation.isOneToOne, let announcesFrom, Date() >= announcesFrom else { return }
        let who = switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.count) people"
        }
        show("\(who) \(what)", symbol: symbol)
    }

    /// Says something on the stage for a few seconds.
    private func show(_ text: String, symbol: String) {
        notice = Notice(text: text, symbol: symbol)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func name(for user: CallParticipantState) -> String {
        if let name = user.displayName ?? nameForSession(user.sessionID) { return name }
        if conversation.isOneToOne { return conversation.displayName }
        return user.actorID ?? user.userID ?? "Guest"
    }

    /// The best layer while there are few enough tiles for it to show; the middle one for more.
    private var preferredLayer: Int {
        participants.count <= 2 ? 2 : 1
    }

    private func send(_ signal: CallSignal, to session: String) async {
        await self.session.signaling.send(.callSignal(toSession: session, signal, nick: nick))
    }

    private func end(reason: String?) {
        tearDown()
        phase = .ended(reason: reason)
        summarizeIfCaptioned()
    }

    /// Notes on what has been said so far — the call goes on.
    func summarizeSoFar() {
        summary.write(from: captions.log.transcript, conversationName: conversation.displayName)
    }

    /// Over: with enough captioned to go on, the notes are written while the end screen shows.
    private func summarizeIfCaptioned() {
        guard captions.log.transcript.count >= CallSummary.minimumLines, summary.state == .idle || hasSummarySoFar else { return }
        summary.write(from: captions.log.transcript, conversationName: conversation.displayName)
    }

    private var hasSummarySoFar: Bool {
        if case .written = summary.state { return true }
        return false
    }

    private func tearDown() {
        screenShare?.stop()
        screenShare = nil
        screenPublisher?.close()
        screenPublisher = nil
        screenTrack = nil
        localScreen = nil
        isSharingScreen = false
        for task in stateRepeats.values { task.cancel() }
        stateRepeats = [:]
        heldOfferRequests = []
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
        announcesFrom = nil
        statsTask?.cancel()
        statsTask = nil
        levelsTask?.cancel()
        levelsTask = nil
        ownSpeaking.silence()
        isSpeaking = false
        speaking = [:]
        measured = []
        capturer?.stopCapture()
        capturer = nil
        videoTrack = nil
        localVideo = nil
        isCameraOn = false
        publisher?.close()
        publisher = nil
        captions.removeAll()
        for peer in subscribers.values { peer.close() }
        subscribers = [:]
        audioTrack = nil
        participants = []
        recentSpeakerID = nil
        isHandRaised = false
        reactions = []
    }
}

/// A video track, compared by which track it is — so a participant with one can still be
/// compared, and a view knows when it was handed another.
final class VideoTrack: Equatable {
    let track: LKRTCVideoTrack

    init(_ track: LKRTCVideoTrack) {
        self.track = track
    }

    static func == (lhs: VideoTrack, rhs: VideoTrack) -> Bool { lhs.track === rhs.track }
}
