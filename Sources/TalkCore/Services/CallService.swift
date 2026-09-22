import Foundation

/// Being in a conversation's call, as far as Nextcloud is concerned: joining starts the call
/// when there is none, and tells everyone else's clients — through the signaling server —
/// that this session is in it and what it sends. The media itself goes through WebRTC.
actor CallService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// Needs the conversation joined first, with the session the signaling server knows.
    func join(token: String, flags: CallFlags, silent: Bool = false) async throws(TalkError) {
        var form = ["flags": String(flags.rawValue)]
        if silent { form["silent"] = "true" }
        _ = try await client.send(OCSRequest.post(Endpoint.call(token), form: form), as: EmptyResponse.self)
    }

    /// What this session sends changed — the microphone or camera on or off.
    func update(token: String, flags: CallFlags) async throws(TalkError) {
        _ = try await client.send(OCSRequest.put(Endpoint.call(token), form: ["flags": String(flags.rawValue)]), as: EmptyResponse.self)
    }

    func leave(token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.call(token)), as: EmptyResponse.self)
    }
}
