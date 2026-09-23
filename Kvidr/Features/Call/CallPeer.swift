import Foundation
@preconcurrency import LiveKitWebRTC

/// One WebRTC connection in a call: this Mac's own media going up to the media server, or one
/// other participant's coming down from it. Negotiation is asked for with async calls; what
/// the connection reports arrives on WebRTC's own thread and is handed to the main actor.
@MainActor
final class CallPeer: NSObject {
    /// The session signals for this connection go to: this client's own for what it sends,
    /// the publisher's for what it receives.
    let remoteSession: String
    /// The negotiation's id, chosen by whoever made the offer.
    var sid: String
    /// `video` for the camera and microphone, `screen` for a shared screen.
    let roomType: String
    let connection: LKRTCPeerConnection

    var onCandidate: (IceCandidate) -> Void = { _ in }
    /// Their camera, once it arrives on a connection that receives.
    var onRemoteVideo: (LKRTCVideoTrack) -> Void = { _ in }
    /// Their voice: for Live Captions, which listen to it on their own.
    var onRemoteAudio: (LKRTCAudioTrack) -> Void = { _ in }
    /// What they say about their microphone and camera, on the "status" data channel.
    var onStatus: (MediaStatus) -> Void = { _ in }

    /// The "status" data channel: made here on the connection that sends, opened by the other
    /// side on one that receives.
    private var statusChannel: LKRTCDataChannel?
    /// Said before the channel was open, sent once it is.
    private var pendingStatus: [MediaStatus] = []
    var onConnectionChange: (_ isConnected: Bool, _ hasFailed: Bool) -> Void = { _, _ in }

    private var hasRemoteDescription = false
    /// Candidates that came before the description they belong to.
    private var pendingCandidates: [LKRTCIceCandidate] = []

    init?(factory: LKRTCPeerConnectionFactory, iceServers: [IceServerConfig], remoteSession: String, sid: String, roomType: String = "video") {
        let configuration = LKRTCConfiguration()
        configuration.iceServers = iceServers.map {
            LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return nil }
        self.connection = connection
        self.remoteSession = remoteSession
        self.sid = sid
        self.roomType = roomType
        super.init()
        connection.delegate = self
    }

    // MARK: - Negotiation

    func makeOffer() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description.sdp) } else { continuation.resume(throwing: error ?? CallError.negotiation) }
            }
        }
    }

    func makeAnswer() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description.sdp) } else { continuation.resume(throwing: error ?? CallError.negotiation) }
            }
        }
    }

    func setLocal(_ type: LKRTCSdpType, sdp: String) async throws {
        let description = LKRTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func setRemote(_ type: LKRTCSdpType, sdp: String) async throws {
        let description = LKRTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        hasRemoteDescription = true
        let pending = pendingCandidates
        pendingCandidates = []
        for candidate in pending { connection.add(candidate) { _ in } }
    }

    func add(_ candidate: IceCandidate) {
        let rtc = LKRTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        if hasRemoteDescription {
            connection.add(rtc) { _ in }
        } else {
            pendingCandidates.append(rtc)
        }
    }

    /// Makes the "status" channel. On the connection that sends, before the offer.
    func openStatusChannel() {
        guard statusChannel == nil,
              let channel = connection.dataChannel(forLabel: "status", configuration: LKRTCDataChannelConfiguration())
        else { return }
        adopt(channel)
    }

    /// Tells the others through the media server, which passes it to everyone receiving.
    func send(_ status: MediaStatus) {
        guard let statusChannel, statusChannel.readyState == .open else {
            pendingStatus.removeAll { $0.isAbout(status) }
            pendingStatus.append(status)
            return
        }
        let sent = statusChannel.sendData(LKRTCDataBuffer(data: status.dataChannelMessage, isBinary: false))
        if status == .videoOn || status == .videoOff {
            Log.sync.notice("Call: said \(status.rawValue) on the status channel\(sent ? "" : " — refused")")
        }
    }

    fileprivate func adopt(_ channel: LKRTCDataChannel) {
        statusChannel = channel
        channel.delegate = self
    }

    fileprivate func channelOpened() {
        Log.sync.notice("Call: status channel open to \(self.remoteSession.prefix(6)) (\(self.roomType)), \(self.pendingStatus.count) waiting")
        let pending = pendingStatus
        pendingStatus = []
        for status in pending { send(status) }
    }

    /// How loud this connection is, 0 to 1 — the microphone going out on the one that sends,
    /// the voice coming in on one that receives. Nil while the connection has nothing to say
    /// about it, which is how a stream that doesn't report levels is told from a quiet one.
    func audioLevel(sending: Bool) async -> Double? {
        let wanted = sending ? "media-source" : "inbound-rtp"
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                var level: Double?
                for stat in report.statistics.values where stat.type == wanted {
                    let values = stat.values
                    guard (values["kind"] as? String) == "audio" else { continue }
                    if let found = (values["audioLevel"] as? NSNumber)?.doubleValue {
                        level = max(level ?? 0, found)
                    }
                }
                continuation.resume(returning: level)
            }
        }
    }

    /// What WebRTC says about the video this connection sends: a line for the log.
    func sentVideoSummary() async -> String {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                var parts: [String] = []
                var codecs: [String: String] = [:]
                for stat in report.statistics.values where stat.type == "codec" {
                    codecs[stat.id] = stat.values["mimeType"].map { "\($0)" }
                }
                for stat in report.statistics.values {
                    let values = stat.values
                    func value(_ key: String) -> String { values[key].map { "\($0)" } ?? "-" }
                    if stat.type == "media-source", value("kind") == "video" {
                        parts.append("camera frames=\(value("frames")) \(value("width"))x\(value("height"))")
                    }
                    if stat.type == "outbound-rtp", value("kind") == "video" {
                        let codec = codecs[value("codecId")] ?? "?"
                        parts.append("sent codec=\(codec) encoded=\(value("framesEncoded")) bytes=\(value("bytesSent")) \(value("frameWidth"))x\(value("frameHeight")) limit=\(value("qualityLimitationReason")) encoder=\(value("encoderImplementation"))")
                    }
                }
                continuation.resume(returning: parts.isEmpty ? "no video stats" : parts.joined(separator: " | "))
            }
        }
    }

    func close() {
        statusChannel?.delegate = nil
        statusChannel?.close()
        connection.delegate = nil
        connection.close()
    }
}

enum CallError: Error {
    case negotiation
}

extension CallPeer: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let found = IceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor in self.onCandidate(found) }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        let connected = newState == .connected
        let failed = newState == .failed
        Task { @MainActor in self.onConnectionChange(connected, failed) }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        guard dataChannel.label == "status" else { return }
        nonisolated(unsafe) let channel = dataChannel
        Task { @MainActor in self.adopt(channel) }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        if let track = rtpReceiver.track as? LKRTCAudioTrack {
            nonisolated(unsafe) let audio = track
            Task { @MainActor in self.onRemoteAudio(audio) }
        }
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        nonisolated(unsafe) let video = track
        Task { @MainActor in self.onRemoteVideo(video) }
    }
}

extension CallPeer: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor in self.channelOpened() }
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let status = MediaStatus(dataChannelMessage: buffer.data) else { return }
        if status == .videoOn || status == .videoOff || status == .audioOn || status == .audioOff {
            Log.sync.notice("Call: heard \(status.rawValue) on a status channel")
        }
        Task { @MainActor in self.onStatus(status) }
    }
}

private extension MediaStatus {
    /// Whether two say something about the same thing, so only the newer is worth sending.
    func isAbout(_ other: MediaStatus) -> Bool {
        switch (self, other) {
        case (.audioOn, .audioOn), (.audioOn, .audioOff), (.audioOff, .audioOn), (.audioOff, .audioOff),
             (.videoOn, .videoOn), (.videoOn, .videoOff), (.videoOff, .videoOn), (.videoOff, .videoOff),
             (.speaking, .speaking), (.speaking, .stoppedSpeaking), (.stoppedSpeaking, .speaking), (.stoppedSpeaking, .stoppedSpeaking):
            true
        default:
            false
        }
    }
}
