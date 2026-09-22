import Foundation
@preconcurrency import WebRTC

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
    let connection: RTCPeerConnection

    var onCandidate: (IceCandidate) -> Void = { _ in }
    var onConnectionChange: (_ isConnected: Bool, _ hasFailed: Bool) -> Void = { _, _ in }

    private var hasRemoteDescription = false
    /// Candidates that came before the description they belong to.
    private var pendingCandidates: [RTCIceCandidate] = []

    init?(factory: RTCPeerConnectionFactory, iceServers: [IceServerConfig], remoteSession: String, sid: String) {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return nil }
        self.connection = connection
        self.remoteSession = remoteSession
        self.sid = sid
        super.init()
        connection.delegate = self
    }

    // MARK: - Negotiation

    func makeOffer() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description.sdp) } else { continuation.resume(throwing: error ?? CallError.negotiation) }
            }
        }
    }

    func makeAnswer() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description.sdp) } else { continuation.resume(throwing: error ?? CallError.negotiation) }
            }
        }
    }

    func setLocal(_ type: RTCSdpType, sdp: String) async throws {
        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func setRemote(_ type: RTCSdpType, sdp: String) async throws {
        let description = RTCSessionDescription(type: type, sdp: sdp)
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
        let rtc = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        if hasRemoteDescription {
            connection.add(rtc) { _ in }
        } else {
            pendingCandidates.append(rtc)
        }
    }

    func close() {
        connection.delegate = nil
        connection.close()
    }
}

enum CallError: Error {
    case negotiation
}

extension CallPeer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let found = IceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor in self.onCandidate(found) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let connected = newState == .connected
        let failed = newState == .failed
        Task { @MainActor in self.onConnectionChange(connected, failed) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
