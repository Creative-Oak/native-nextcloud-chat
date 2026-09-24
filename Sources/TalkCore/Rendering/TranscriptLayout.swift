import Foundation

/// Whether a message starts a new visual group.
///
/// Consecutive messages from one person, close together in time and on the same day, are
/// shown as a single run with one avatar and one name — the way Messages does it. Repeating
/// the avatar on every line is the single most "web app" thing a chat transcript can do.
struct MessageGroupContext: Sendable, Equatable {
    var showsHeader: Bool
    var showsAvatar: Bool

    static let groupingWindow: TimeInterval = 5 * 60

    static func between(previous: Message?, current: Message) -> MessageGroupContext {
        guard !current.isSystem else {
            return MessageGroupContext(showsHeader: false, showsAvatar: false)
        }
        guard let previous, !previous.isSystem else {
            return MessageGroupContext(showsHeader: true, showsAvatar: true)
        }

        let sameAuthor = previous.actor.id == current.actor.id && previous.actor.kind == current.actor.kind
        let closeInTime = current.timestamp.timeIntervalSince(previous.timestamp) < groupingWindow
        let sameDay = Calendar.current.isDate(previous.timestamp, inSameDayAs: current.timestamp)
        // A pending message still groups with the ones before it: the bubble shouldn't
        // visibly re-parent itself when the server acknowledges it.
        let grouped = sameAuthor && closeInTime && sameDay

        return MessageGroupContext(showsHeader: !grouped, showsAvatar: !grouped)
    }
}

/// One row of the transcript: a message, a day divider, or the unread marker.
///
/// Built once per timeline change rather than once per render — rebuilding this in every
/// SwiftUI body pass is the standard way a chat view starts dropping frames at a few
/// thousand messages.
struct ChatRow: Sendable, Identifiable, Equatable {
    enum Kind: Sendable, Equatable {
        case message(Message, MessageGroupContext)
        case daySeparator(Date)
        case unreadSeparator
    }

    let id: String
    let kind: Kind

    var message: Message? {
        if case .message(let message, _) = kind { return message } else { return nil }
    }

    var isUnreadSeparator: Bool { kind == .unreadSeparator }

    /// Builds the display list: day separators where the date changes, the unread marker
    /// where the user last left off, and grouping flags for each message.
    ///
    /// Invisible system messages (`message_deleted`, `reaction`, …) are dropped here — they
    /// exist to update the cache, not to be read.
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
                rows.append(ChatRow(id: "day-\(Int(day.timeIntervalSince1970))", kind: .daySeparator(day)))
                lastDay = day
                // A day boundary also breaks grouping, however close the messages are.
                previous = nil
            }

            if let firstUnreadMessageID, !hasPlacedUnreadMarker, message.messageID >= firstUnreadMessageID {
                rows.append(ChatRow(id: "unread-marker", kind: .unreadSeparator))
                hasPlacedUnreadMarker = true
                previous = nil
            }

            rows.append(ChatRow(
                id: message.localID,
                kind: .message(message, MessageGroupContext.between(previous: previous, current: message))
            ))
            previous = message
        }

        return rows
    }
}

/// The one-line summary shown in the sidebar and in notifications.
enum ConversationPreview {
    /// What stands in for the last message of a sensitive conversation.
    static let hiddenText = String(localized: "Preview hidden", comment: "Stands in for the last message of a sensitive conversation")

    /// - Parameter includeSender: group conversations prefix the sender's name; one-to-ones
    ///   don't, because you already know who it is.
    static func text(for conversation: Conversation) -> String {
        if conversation.isSensitive { return hiddenText }
        guard let message = conversation.lastMessage else {
            return conversation.isNoteToSelf
                ? String(localized: "Notes to yourself", comment: "Sidebar preview of an empty note-to-self conversation")
                : String(localized: "No messages yet", comment: "Sidebar preview of an empty conversation")
        }

        let body = MessageContentParser(currentUserID: "", markdownEnabled: false)
            .parse(message)
            .preview

        guard !message.isSystem, !conversation.isOneToOne else { return body }
        let sender = message.actor.resolvedDisplayName
        guard !sender.isEmpty else { return body }
        return String(localized: "\(sender): \(body)", comment: "Sidebar preview: sender name, then the message")
    }
}

/// Sidebar and separator timestamps.
///
/// Compact and relative, the way Mail and Messages do it: a time today, "Yesterday", a
/// weekday within the last week, then a date.
enum RelativeTimestamp {
    // `locale` is injected for the same reason `now` and `calendar` are: the formatted
    // branches below are locale-dependent (a Danish Mac renders 13.00 and "tirs.", a US
    // one 1:00 PM and "Tue"), so a test that doesn't pin it asserts whatever the machine
    // running it happens to be set to.
    static func sidebar(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
        }
        return date.formatted(.dateTime.day().month(.defaultDigits).locale(locale))
    }

    static func daySeparator(
        _ day: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), day > weekAgo {
            return day.formatted(.dateTime.weekday(.wide).locale(locale))
        }
        return day.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(locale)
        )
    }
}
