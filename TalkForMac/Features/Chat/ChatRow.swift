import Foundation

/// One row of the transcript: a message, a day divider, or the unread marker.
///
/// Built once per timeline change rather than once per render. Rebuilding this on every
/// SwiftUI body pass is the standard way a chat view starts dropping frames at a few
/// thousand messages.
struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case message(Message, MessageGroupContext)
        case daySeparator(Date)
        case unreadSeparator
    }

    let id: String
    let kind: Kind

    var message: Message? {
        if case .message(let message, _) = kind { return message } else { return nil }
    }

    /// Builds the display list: day separators where the date changes, the unread marker
    /// where the user last left off, and grouping flags for each message.
    static func build(
        messages: [Message],
        firstUnreadMessageID: Int?,
        calendar: Calendar = .current
    ) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count + 8)

        var previous: Message?
        var lastDay: Date?
        var hasPlacedUnreadMarker = false

        for message in messages where message.isVisible {
            let day = calendar.startOfDay(for: message.timestamp)
            if lastDay != day {
                rows.append(ChatRow(id: "day-\(day.timeIntervalSince1970)", kind: .daySeparator(day)))
                lastDay = day
                // A day boundary also breaks grouping.
                previous = nil
            }

            if let firstUnreadMessageID, !hasPlacedUnreadMarker, message.messageID >= firstUnreadMessageID {
                rows.append(ChatRow(id: "unread-marker", kind: .unreadSeparator))
                hasPlacedUnreadMarker = true
                previous = nil
            }

            let group = MessageGroupContext.between(previous: previous, current: message)
            rows.append(ChatRow(id: message.localID, kind: .message(message, group)))
            previous = message
        }

        return rows
    }
}
