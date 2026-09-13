import Foundation

/// `GET /room/{token}/participants`. Field names verified against Talk's OpenAPI schema.
struct ParticipantDTO: Decodable, Sendable {
    let attendeeId: Int
    let actorId: String
    let actorType: String
    let invitedActorId: String?
    let displayName: String?
    let participantType: Int?
    let permissions: Int?
    let attendeePermissions: Int?
    let lastPing: Int?
    let inCall: Int?
    let sessionIds: [String]?
    let status: String?
    let statusIcon: String?
    let statusMessage: String?
    let statusClearAt: Int?

    private enum CodingKeys: String, CodingKey {
        case attendeeId, actorId, actorType, invitedActorId, displayName, participantType
        case permissions, attendeePermissions, lastPing, inCall, sessionIds
        case status, statusIcon, statusMessage, statusClearAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attendeeId = Lenient.int(container, .attendeeId) ?? 0
        actorId = Lenient.string(container, .actorId) ?? ""
        actorType = (try? container.decodeIfPresent(String.self, forKey: .actorType)) ?? "users"
        invitedActorId = try? container.decodeIfPresent(String.self, forKey: .invitedActorId)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        participantType = Lenient.int(container, .participantType)
        permissions = Lenient.int(container, .permissions)
        attendeePermissions = Lenient.int(container, .attendeePermissions)
        lastPing = Lenient.int(container, .lastPing)
        inCall = Lenient.int(container, .inCall)
        sessionIds = try? container.decodeIfPresent([String].self, forKey: .sessionIds)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        statusIcon = try? container.decodeIfPresent(String.self, forKey: .statusIcon)
        statusMessage = try? container.decodeIfPresent(String.self, forKey: .statusMessage)
        statusClearAt = Lenient.int(container, .statusClearAt)
    }

    func model() -> Participant {
        var userStatus: UserStatus?
        if let status, !status.isEmpty {
            userStatus = UserStatus(
                status: status,
                icon: statusIcon,
                message: statusMessage,
                clearAt: statusClearAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }

        // Talk sends "0" as the session id for a participant with no session.
        let sessions = (sessionIds ?? []).filter { $0 != "0" && !$0.isEmpty }

        return Participant(
            attendeeID: attendeeId,
            actor: MessageActor(type: actorType, id: actorId, displayName: displayName),
            participantType: ParticipantType(rawValue: participantType ?? 3),
            permissions: ConversationPermissions(rawValue: permissions ?? 0),
            attendeePermissions: ConversationPermissions(rawValue: attendeePermissions ?? 0),
            lastPing: (lastPing ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(lastPing ?? 0)) : nil,
            inCall: inCall ?? 0,
            sessionIDs: sessions,
            status: userStatus,
            invitedActorID: invitedActorId
        )
    }
}

/// `GET /ocs/v2.php/core/autocomplete/get`. Shape verified against Nextcloud core's
/// OpenAPI `AutocompleteResult` schema.
struct AutocompleteResultDTO: Decodable, Sendable {
    let id: String
    let label: String?
    let icon: String?
    let source: String?
    let subline: String?
    let shareWithDisplayNameUnique: String?
    let status: StatusDTO?

    /// `status` is an object when the user has one and an **empty string** when they don't,
    /// which is exactly the sort of thing that fails a naive decoder.
    struct StatusDTO: Decodable, Sendable {
        let status: String?
        let message: String?
        let icon: String?
        let clearAt: Int?

        init(from decoder: any Decoder) throws {
            enum Key: String, CodingKey { case status, message, icon, clearAt }
            guard let container = try? decoder.container(keyedBy: Key.self) else {
                status = nil; message = nil; icon = nil; clearAt = nil
                return
            }
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            icon = try? container.decodeIfPresent(String.self, forKey: .icon)
            clearAt = Lenient.int(container, .clearAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, icon, source, subline, shareWithDisplayNameUnique, status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Lenient.string(container, .id) ?? ""
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        icon = try? container.decodeIfPresent(String.self, forKey: .icon)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        subline = try? container.decodeIfPresent(String.self, forKey: .subline)
        shareWithDisplayNameUnique = try? container.decodeIfPresent(String.self, forKey: .shareWithDisplayNameUnique)
        status = try? container.decodeIfPresent(StatusDTO.self, forKey: .status)
    }

    func model() -> DirectoryEntry {
        var userStatus: UserStatus?
        if let raw = status?.status, !raw.isEmpty {
            userStatus = UserStatus(
                status: raw,
                icon: status?.icon,
                message: status?.message,
                clearAt: status?.clearAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }

        let detail = [subline, shareWithDisplayNameUnique]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        return DirectoryEntry(
            identifier: id,
            label: label?.isEmpty == false ? label! : id,
            source: DirectoryEntry.Source(rawValue: source ?? "users"),
            subline: detail,
            status: userStatus
        )
    }
}
