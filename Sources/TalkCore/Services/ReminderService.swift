import Foundation

/// A reminder the user set on a message, from the list of upcoming ones.
struct Reminder: Sendable, Hashable, Identifiable {
    var token: String
    var messageID: Int
    var date: Date
    /// The message, as the server quotes it in the list. Empty when the reminder came back
    /// from setting it, which says only where and when.
    var actor: MessageActor
    var text: String
    var parameters: [String: RichObject]

    var id: String { "\(token)/\(messageID)" }
}

/// When a reminder can be set for, as the message menu offers them.
struct ReminderPreset: Sendable, Hashable, Identifiable {
    var title: String
    var date: Date

    var id: String { title }

    /// The choices on offer at `now`: a few relative ones, then fixed times of day. "Later
    /// Today" drops out once the evening is too close to be later.
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [ReminderPreset] {
        var presets = [
            ReminderPreset(title: "In 30 Minutes", date: now.addingTimeInterval(30 * 60)),
            ReminderPreset(title: "In 1 Hour", date: now.addingTimeInterval(60 * 60)),
            ReminderPreset(title: "In 3 Hours", date: now.addingTimeInterval(3 * 60 * 60)),
        ]

        let today = calendar.startOfDay(for: now)
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today),
           evening.timeIntervalSince(now) >= 60 * 60 {
            presets.append(ReminderPreset(title: "Later Today", date: evening))
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return presets }
        if let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            presets.append(ReminderPreset(title: "Tomorrow", date: morning))
        }
        // The first Monday from tomorrow on, at nine — so on a Monday it is the one after.
        if let monday = calendar.nextDate(
            after: tomorrow.addingTimeInterval(-1),
            matching: DateComponents(hour: 9, minute: 0, weekday: 2),
            matchingPolicy: .nextTime
        ) {
            presets.append(ReminderPreset(title: "Next Week", date: monday))
        }
        return presets
    }
}

/// Reminders on messages. Cap `remind-me-later`; the list of upcoming ones is cap
/// `upcoming-reminders`. When one comes due, Nextcloud sends its own notification and
/// takes it off the list.
actor ReminderService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func setReminder(token: String, messageID: Int, at date: Date) async throws(TalkError) {
        let form = ["timestamp": String(Int(date.timeIntervalSince1970))]
        _ = try await client.send(OCSRequest.post(Endpoint.reminder(token, messageID), form: form), as: EmptyResponse.self)
    }

    func deleteReminder(token: String, messageID: Int) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.reminder(token, messageID)), as: EmptyResponse.self)
    }

    /// Every reminder still to come, in every conversation, soonest first.
    func upcoming() async throws(TalkError) -> [Reminder] {
        let response = try await client.send(OCSRequest.get(Endpoint.upcomingReminders), as: [UpcomingReminderDTO].self)
        return (response.value ?? []).map { $0.model() }.sorted { $0.date < $1.date }
    }
}

/// One entry of `GET /chat/upcoming-reminders`.
struct UpcomingReminderDTO: Decodable, Sendable {
    let roomToken: String
    let messageId: Int
    let reminderTimestamp: Int
    let actorType: String
    let actorId: String
    let actorDisplayName: String?
    let message: String
    let messageParameters: [String: RichObjectDTO]

    private enum CodingKeys: String, CodingKey {
        case roomToken, messageId, reminderTimestamp, actorType, actorId, actorDisplayName, message, messageParameters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomToken = (try? container.decodeIfPresent(String.self, forKey: .roomToken)) ?? ""
        messageId = Lenient.int(container, .messageId) ?? 0
        reminderTimestamp = Lenient.int(container, .reminderTimestamp) ?? 0
        actorType = (try? container.decodeIfPresent(String.self, forKey: .actorType)) ?? ""
        actorId = Lenient.string(container, .actorId) ?? ""
        actorDisplayName = try? container.decodeIfPresent(String.self, forKey: .actorDisplayName)
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        // `[]` rather than `{}` when empty, as everywhere in Talk.
        messageParameters = (try? container.decodeIfPresent([String: RichObjectDTO].self, forKey: .messageParameters)) ?? [:]
    }

    func model() -> Reminder {
        Reminder(
            token: roomToken,
            messageID: messageId,
            date: Date(timeIntervalSince1970: TimeInterval(reminderTimestamp)),
            actor: MessageActor(type: actorType, id: actorId, displayName: actorDisplayName),
            text: message,
            parameters: messageParameters.objects
        )
    }
}
