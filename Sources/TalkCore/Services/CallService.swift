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

    /// - Parameter everyone: ends the call for everyone in it, not just this session — what a
    ///   one-to-one's hang-up does in Talk's apps, and what moderators can do in a group.
    /// Whether a call should still be ringing for this user: the question Talk's apps ask while
    /// they ring. Cap `call-notification-state-api`.
    func notificationState(token: String) async throws(TalkError) -> CallNotificationState {
        do {
            let response = try await client.send(OCSRequest.get(Endpoint.callNotificationState(token)), as: EmptyResponse.self)
            return response.status == 201 ? .missed : .ringing
        } catch .notFound {
            return .over
        }
    }

    func leave(token: String, everyone: Bool = false) async throws(TalkError) {
        let request = OCSRequest.delete(Endpoint.call(token), form: everyone ? ["all": "true"] : [:])
        _ = try await client.send(request, as: EmptyResponse.self)
    }
}

/// What a ringing call should do now, as the server sees it.
enum CallNotificationState: Sendable, Equatable {
    /// Keep ringing.
    case ringing
    /// Stop: nobody answered, and it's a missed call now.
    case missed
    /// Stop: answered on another device, or the caller gave up.
    case over
}
