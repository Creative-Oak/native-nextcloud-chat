import AVFoundation
import CoreAudio
import Foundation
@preconcurrency import WebRTC

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
        /// Their camera, once it has arrived.
        var video: VideoTrack?

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
    private(set) var isMuted = false
    private(set) var isCameraOn = false
    /// This Mac's camera, to show in the corner.
    private(set) var localVideo: VideoTrack?
    /// The cameras to choose from, and the one in use.
    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var cameraID: String?
    /// Why the camera didn't come on, until the next try.
    private(set) var cameraProblem: String?
    /// When this Mac's own connection came up.
    private(set) var connectedAt: Date?
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
    @ObservationIgnored private var subscribers: [String: CallPeer] = [:]
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
    @ObservationIgnored private var videoTrack: RTCVideoTrack?
    @ObservationIgnored private var capturer: RTCCameraVideoCapturer?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// The state being said again, per session — "" for everyone. See ``repeatState(to:)``.
    @ObservationIgnored private var stateRepeats: [String: Task<Void, Never>] = [:]
    /// Made afresh for each start of the call's media: its audio opens the Mac's default
    /// microphone and speaker then, and keeps them.
    @ObservationIgnored private var factory = CallController.makeFactory()
    /// The microphones and speakers to choose from.
    let audioDevices = AudioDevices()

    private static let sslReady: Void = { RTCInitializeSSL() }()

    private static func makeFactory() -> RTCPeerConnectionFactory {
        _ = sslReady
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }

    init(session: Session, conversation: Conversation, ownSessionID: String, iceServers: [IceServerConfig],
         nick: String, nameForSession: @escaping (String) -> String?) {
        self.session = session
        self.conversation = conversation
        self.token = conversation.token
        self.ownSessionID = ownSessionID
        self.iceServers = iceServers
        self.nick = nick
        self.nameForSession = nameForSession
        self.roster = CallRoster(ownSessionID: ownSessionID)
    }

    // MARK: - Joining and leaving

    /// Joins — starting the call if nobody is in it — and starts sending the microphone.
    func join() async {
        // Left meanwhile — say, while the audio was restarting: don't walk back in.
        guard phase == .joining else { return }
        Log.sync.notice("Call: joining")
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
        factory = Self.makeFactory()
        phase = .joining
        try? await session.calls.leave(token: token)
        await join()
    }

    func toggleMute() {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
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
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
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

    /// Someone new hears where things stand.
    private func tellCurrentState(to id: String) {
        repeatState(to: id)
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
                    if id == nil { self.publisher?.send(status) }
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
        case .speaking, .stoppedSpeaking: break
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
        switch signal.kind {
        case .answer(let sdp) where sender == ownSessionID:
            guard let publisher else { return }
            Task { try? await publisher.setRemote(.answer, sdp: sdp) }
        case .offer(let sdp) where sender != ownSessionID:
            Task { await subscribe(to: sender, offer: sdp, sid: signal.sid ?? UUID().uuidString) }
        case .candidate(let candidate):
            let peer = sender == ownSessionID ? publisher : subscribers[sender]
            peer?.add(candidate)
        default:
            break
        }
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
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio")
        track.isEnabled = !isMuted
        let options = RTCRtpTransceiverInit()
        options.direction = .sendOnly
        options.streamIds = [ownSessionID]
        peer.connection.addTransceiver(with: track, init: options)
        audioTrack = track

        // The camera's track, off until the camera is turned on — there from the start even
        // without a camera, so one plugged in later needs no new connection.
        cameras = Self.findCameras()
        do {
            let videoSource = factory.videoSource()
            let video = factory.videoTrack(with: videoSource, trackId: "video")
            video.isEnabled = isCameraOn
            let videoOptions = RTCRtpTransceiverInit()
            videoOptions.direction = .sendOnly
            videoOptions.streamIds = [ownSessionID]
            peer.connection.addTransceiver(with: video, init: videoOptions)
            videoTrack = video
            localVideo = VideoTrack(video)
            capturer = RTCCameraVideoCapturer(delegate: videoSource)
        }
        peer.openStatusChannel()
        publisher = peer
        wire(peer)
        peer.onConnectionChange = { [weak self] connected, failed in
            guard let self else { return }
            Log.sync.notice("Call: publisher connected=\(connected) failed=\(failed)")
            if connected, self.connectedAt == nil { self.connectedAt = Date() }
            if connected, self.phase == .joining { self.phase = .inCall }
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

    private func subscribe(to sessionID: String, offer: String, sid: String) async {
        subscribers[sessionID]?.close()
        guard !isEnded,
              let peer = CallPeer(factory: factory, iceServers: iceServers, remoteSession: sessionID, sid: sid)
        else { return }
        subscribers[sessionID] = peer
        wire(peer)
        peer.onRemoteVideo = { [weak self] track in
            guard let self, let index = self.participants.firstIndex(where: { $0.id == sessionID }) else { return }
            self.participants[index].video = VideoTrack(track)
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
            Task { await self.send(CallSignal(kind: .candidate(candidate), sid: peer.sid), to: peer.remoteSession) }
        }
    }

    private func apply(_ change: CallRoster.Change) {
        for id in change.toDrop {
            subscribers.removeValue(forKey: id)?.close()
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
            let session = user.sessionID
            Log.sync.notice("Call: requesting offer from \(session.prefix(6))")
            Task { await self.send(CallSignal(kind: .requestOffer), to: session) }
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
    }

    private func tearDown() {
        for task in stateRepeats.values { task.cancel() }
        stateRepeats = [:]
        statsTask?.cancel()
        statsTask = nil
        capturer?.stopCapture()
        capturer = nil
        videoTrack = nil
        localVideo = nil
        isCameraOn = false
        publisher?.close()
        publisher = nil
        for peer in subscribers.values { peer.close() }
        subscribers = [:]
        audioTrack = nil
        participants = []
    }
}

/// A video track, compared by which track it is — so a participant with one can still be
/// compared, and a view knows when it was handed another.
final class VideoTrack: Equatable {
    let track: RTCVideoTrack

    init(_ track: RTCVideoTrack) {
        self.track = track
    }

    static func == (lhs: VideoTrack, rhs: VideoTrack) -> Bool { lhs.track === rhs.track }
}
