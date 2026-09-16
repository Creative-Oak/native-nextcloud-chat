import Foundation

/// The signed-in user's status, through the `user_status` app's OCS API.
///
/// None of these need a confirmed password, which is why status is editable in the app when
/// the rest of the profile is not.
struct UserStatusService: Sendable {
    let client: OCSClient

    /// Nil-free: a user who has never set a status is answered with a 404, and that user is
    /// simply online with no message.
    func status() async throws(TalkError) -> OwnStatus {
        do throws(TalkError) {
            return try await client.require(OCSRequest.get(Endpoint.userStatus), as: OwnStatusDTO.self).value.status
        } catch {
            if error == .notFound { return .unset }
            throw error
        }
    }

    func predefinedStatuses() async throws(TalkError) -> [PredefinedStatus] {
        let response = try await client.send(OCSRequest.get(Endpoint.predefinedStatuses), as: [PredefinedStatusDTO].self)
        return (response.value ?? []).compactMap(\.status)
    }

    func setStatus(_ status: OnlineStatus) async throws(TalkError) -> OwnStatus {
        try await client.require(
            OCSRequest.put(Endpoint.userStatusType, form: ["statusType": status.rawValue]),
            as: OwnStatusDTO.self
        ).value.status
    }

    /// A message of the user's own. An empty icon and message with no clear time clears it,
    /// which is how the server reads that too.
    func setCustomMessage(icon: String?, message: String?, clearAt: Date?) async throws(TalkError) -> OwnStatus {
        var form: [String: String] = [:]
        if let icon, !icon.isEmpty { form["statusIcon"] = icon }
        if let message, !message.isEmpty { form["message"] = message }
        if let clearAt { form["clearAt"] = String(Int(clearAt.timeIntervalSince1970)) }
        return try await client.require(OCSRequest.put(Endpoint.userStatusCustomMessage, form: form), as: OwnStatusDTO.self)
            .value.status
    }

    func setPredefinedMessage(id: String, clearAt: Date?) async throws(TalkError) -> OwnStatus {
        var form = ["messageId": id]
        if let clearAt { form["clearAt"] = String(Int(clearAt.timeIntervalSince1970)) }
        return try await client.require(OCSRequest.put(Endpoint.userStatusPredefinedMessage, form: form), as: OwnStatusDTO.self)
            .value.status
    }

    func clearMessage() async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.userStatusMessage), as: EmptyResponse.self)
    }
}
