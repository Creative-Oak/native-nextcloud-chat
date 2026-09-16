import Foundation

/// The presence part of a status.
enum OnlineStatus: String, Sendable, Hashable, CaseIterable {
    case online, away, dnd, busy, invisible, offline

    var title: String {
        switch self {
        case .online: "Online"
        case .away: "Away"
        case .dnd: "Do not disturb"
        case .busy: "Busy"
        case .invisible: "Invisible"
        case .offline: "Offline"
        }
    }

    /// What someone can pick. `offline` is what the server reports, not a choice; your own
    /// `invisible` is reported back as itself.
    static func choosable(supportsBusy: Bool) -> [OnlineStatus] {
        supportsBusy ? [.online, .away, .busy, .dnd, .invisible] : [.online, .away, .dnd, .invisible]
    }
}

/// The signed-in user's status, as `GET /apps/user_status/api/v1/user_status` has it.
struct OwnStatus: Sendable, Hashable {
    var status: OnlineStatus
    var message: String?
    var icon: String?
    /// When the message clears itself. Nil means it stays until changed.
    var clearAt: Date?
    var messageID: String?
    var messageIsPredefined: Bool

    /// What a user who has never set anything has, which the server answers with a 404.
    static let unset = OwnStatus(status: .online, message: nil, icon: nil, clearAt: nil, messageID: nil, messageIsPredefined: false)

    var hasMessage: Bool {
        !(message ?? "").isEmpty || !(icon ?? "").isEmpty
    }
}

/// When a status message should clear itself.
enum ClearAfter: Sendable, Hashable, CaseIterable {
    case never
    case thirtyMinutes
    case oneHour
    case fourHours
    case today
    case thisWeek

    var title: String {
        switch self {
        case .never: "Don’t clear"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .today: "Today"
        case .thisWeek: "This week"
        }
    }

    /// The moment to send as `clearAt`. "Today" and "this week" end where the user's own
    /// calendar says they do, which is also how the web UI works them out.
    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .never:
            return nil
        case .thirtyMinutes:
            return now.addingTimeInterval(30 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .fourHours:
            return now.addingTimeInterval(4 * 60 * 60)
        case .today:
            return calendar.dateInterval(of: .day, for: now)?.end
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.end
        }
    }
}

/// One of the server's ready-made messages — "In a meeting", "Commuting".
struct PredefinedStatus: Sendable, Hashable, Identifiable {
    let id: String
    let icon: String
    let message: String
    let clearAfter: ClearAfter
}

// MARK: - Wire format

struct OwnStatusDTO: Decodable, Sendable {
    let status: OwnStatus

    private enum CodingKeys: String, CodingKey {
        case status, message, icon, clearAt, messageId, messageIsPredefined
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = Lenient.string(container, .status) ?? "online"
        status = OwnStatus(
            status: OnlineStatus(rawValue: raw) ?? .online,
            message: Lenient.string(container, .message),
            icon: Lenient.string(container, .icon),
            clearAt: Lenient.int(container, .clearAt).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            messageID: Lenient.string(container, .messageId),
            messageIsPredefined: Lenient.bool(container, .messageIsPredefined) ?? false
        )
    }
}

struct PredefinedStatusDTO: Decodable, Sendable {
    let status: PredefinedStatus?

    private enum CodingKeys: String, CodingKey { case id, icon, message, clearAt }
    private enum ClearKeys: String, CodingKey { case type, time }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Lenient.string(container, .id), let message = Lenient.string(container, .message) else {
            status = nil
            return
        }

        var clearAfter = ClearAfter.never
        if let clear = try? container.nestedContainer(keyedBy: ClearKeys.self, forKey: .clearAt) {
            let type = Lenient.string(clear, .type)
            if type == "end-of" {
                switch Lenient.string(clear, .time) {
                case "day": clearAfter = .today
                case "week": clearAfter = .thisWeek
                default: break
                }
            } else if type == "period", let seconds = Lenient.int(clear, .time) {
                // The server's periods are these three; anything else is closest to never.
                switch seconds {
                case 1800: clearAfter = .thirtyMinutes
                case 3600: clearAfter = .oneHour
                case 14400: clearAfter = .fourHours
                default: break
                }
            }
        }

        status = PredefinedStatus(id: id, icon: Lenient.string(container, .icon) ?? "", message: message, clearAfter: clearAfter)
    }
}
