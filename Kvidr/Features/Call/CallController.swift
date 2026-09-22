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
    /// When this Mac's own connection came up.
    private(set) var connectedAt: Date?

    @ObservationIgnored private let session: Session
    @ObservationIgnored private let ownSessionID: String
    @ObservationIgnored private let iceServers: [IceServerConfig]
    @ObservationIgnored private let nick: String
    @ObservationIgnored private let nameForSession: (String) -> String?
    @ObservationIgnored private var roster: CallRoster
    @ObservationIgnored private var publisher: CallPeer?
    @ObservationIgnored private var subscribers: [String: CallPeer] = [:]
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
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
        do throws(TalkError) {
            try await session.calls.join(token: token, flags: [.inCall, .withAudio])
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

    func leave() {
        guard !isEnded else { return }
        tearDown()
        phase = .ended(reason: nil)
        let calls = session.calls
        let token = self.token
        Task { try? await calls.leave(token: token) }
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
        peer.onConnectionChange = { [weak self] connected, failed in
            Log.sync.notice("Call: subscriber \(sessionID.prefix(6)) connected=\(connected) failed=\(failed)")
            guard let self, let index = self.participants.firstIndex(where: { $0.id == sessionID }) else { return }
            self.participants[index].isConnected = connected
        }
        do {
            try await peer.setRemote(.offer, sdp: offer)
            let answer = try await peer.makeAnswer()
            try await peer.setLocal(.answer, sdp: answer)
            await send(CallSignal(kind: .answer(sdp: answer), sid: sid), to: sessionID)
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
                    name: name(for: user)
                ))
            }
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

    private func send(_ signal: CallSignal, to session: String) async {
        await self.session.signaling.send(.callSignal(toSession: session, signal, nick: nick))
    }

    private func end(reason: String?) {
        tearDown()
        phase = .ended(reason: reason)
    }

    private func tearDown() {
        publisher?.close()
        publisher = nil
        for peer in subscribers.values { peer.close() }
        subscribers = [:]
        audioTrack = nil
        participants = []
    }
}
