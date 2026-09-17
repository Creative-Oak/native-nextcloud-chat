import Foundation

/// One entry in the user's Nextcloud notifications, as far as kvidr cares about it.
struct ServerNotification: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        /// Someone is calling, or a call started, in a conversation.
        case call(token: String)
        /// A mention, a message in a one-to-one, a reply, a reaction.
        case chat(token: String)
        /// A reminder coming due. kvidr schedules these with macOS itself.
        case reminder(token: String)
        /// Added to a conversation.
        case invitation(token: String)
        case other
    }

    let id: Int
    let kind: Kind
    /// The notification's words, already written out by the server in the user's language.
    let subject: String
    let message: String
    /// Where the web opens it — only ever a web link.
    let link: URL?
    let date: Date?
}

/// Nextcloud's notifications list. It covers every conversation in one request, and with an
/// `ETag` an unchanged list comes back as `304` and costs next to nothing — which is what makes
/// it cheap enough to ask often while kvidr is in the background.
actor NotificationsService {
    enum Outcome: Sendable, Equatable {
        case changed([ServerNotification], etag: String?)
        case unchanged
        /// The notifications app isn't there, or nothing uses it. Not worth asking again.
        case unavailable
    }

    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func notifications(etag: String?) async throws(TalkError) -> Outcome {
        var request = OCSRequest.get(Endpoint.notifications)
        if let etag { request.headers["If-None-Match"] = etag }
        let response: OCSResponse<[ServerNotificationDTO]?>
        do throws(TalkError) {
            response = try await client.send(request, as: [ServerNotificationDTO].self)
        } catch .notFound {
            return .unavailable
        }
        switch response.status {
        case 304: return .unchanged
        case 204: return .unavailable
        default:
            let items = (response.value ?? []).compactMap { $0.model() }
            return .changed(items, etag: response.headers["ETag"])
        }
    }
}

struct ServerNotificationDTO: Decodable, Sendable {
    let notificationId: Int?
    let app: String?
    let objectType: String?
    let objectId: String?
    let subject: String?
    let message: String?
    let link: String?
    let datetime: String?

    private enum CodingKeys: String, CodingKey {
        case notificationId = "notification_id"
        case app
        case objectType = "object_type"
        case objectId = "object_id"
        case subject, message, link, datetime
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationId = Lenient.int(container, .notificationId)
        app = try? container.decodeIfPresent(String.self, forKey: .app)
        objectType = try? container.decodeIfPresent(String.self, forKey: .objectType)
        objectId = Lenient.string(container, .objectId)
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        link = try? container.decodeIfPresent(String.self, forKey: .link)
        datetime = try? container.decodeIfPresent(String.self, forKey: .datetime)
    }

    func model() -> ServerNotification? {
        guard let id = notificationId else { return nil }
        return ServerNotification(
            id: id,
            kind: kind,
            subject: subject ?? "",
            message: message ?? "",
            link: link.flatMap(URL.init(string:)).flatMap { $0.isWebLink ? $0 : nil },
            date: datetime.flatMap { try? Date($0, strategy: .iso8601) }
        )
    }

    /// Talk's own notifications name their conversation in `object_id`: the token alone, or
    /// `token/messageId`.
    private var kind: ServerNotification.Kind {
        guard app == "spreed", let objectId, !objectId.isEmpty else { return .other }
        let token = String(objectId.split(separator: "/").first ?? "")
        guard !token.isEmpty else { return .other }
        switch objectType {
        case "call": return .call(token: token)
        case "chat": return subject == "reminder" ? .reminder(token: token) : .chat(token: token)
        case "reminder": return .reminder(token: token)
        case "room": return .invitation(token: token)
        default: return .other
        }
    }
}
