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

/// Consecutive system events that read as one: everyone who came and went during a call,
/// or the people one person added. Shown as a single line that opens to the events, the
/// way Talk's web client does it — a call otherwise leaves a stack of "joined" and "left"
/// lines between the messages around it.
struct SystemMessageGroup: Sendable, Equatable {
    /// In order, at least two.
    let messages: [Message]
    let summary: String

    /// - Parameter locale: how names are joined ("Anna and Bo", "Anna og Bo"). Injected so
    ///   tests don't assert whatever the machine running them is set to.
    init(messages: [Message], isMe: (MessageActor) -> Bool = { _ in false }, locale: Locale = .current) {
        self.messages = messages
        self.summary = Self.summary(of: messages, isMe: isMe, locale: locale)
    }

    /// What decides which events share a line: the same key, next to each other. Nil for
    /// anything that always stands on its own.
    static func key(for message: Message) -> String? {
        guard message.isSystem else { return nil }
        let actor = "\(message.actor.kind.rawValue)/\(message.actor.id)"
        switch message.systemMessage {
        // Anyone's comings and goings: they are all the one call.
        case "call_joined", "call_left": return "call"
        // Only one person's: "Anna added Bo and Carl" has one subject.
        case "user_added": return "user_added:\(actor)"
        case "user_removed": return "user_removed:\(actor)"
        default: return nil
        }
    }

    private static func summary(of messages: [Message], isMe: (MessageActor) -> Bool, locale: Locale) -> String {
        guard let first = messages.first else { return "" }
        switch first.systemMessage {
        case "call_joined", "call_left":
            // Each person once, you first, then in the order they turned up.
            var people: [MessageActor] = []
            for message in messages where !people.contains(where: { same($0, message.actor) }) {
                people.append(message.actor)
            }
            people = people.filter(isMe) + people.filter { !isMe($0) }
            let who = names(people.map { isMe($0) ? you : $0.resolvedDisplayName }, locale: locale)
            let joined = messages.contains { $0.systemMessage == "call_joined" }
            let left = messages.contains { $0.systemMessage == "call_left" }
            switch (joined, left) {
            case (true, false):
                return String(localized: "\(who) joined the call", comment: "Collapsed call events: one or more names")
            case (false, true):
                return String(localized: "\(who) left the call", comment: "Collapsed call events: one or more names")
            default:
                return String(localized: "\(who) joined and left the call", comment: "Collapsed call events: one or more names")
            }
        default:
            let actor = isMe(first.actor) ? you : first.actor.resolvedDisplayName
            var seen: Set<String> = []
            let people = messages.compactMap { message -> String? in
                guard let user = message.parameters["user"], seen.insert("\(user.type.rawValue)/\(user.id)").inserted
                else { return nil }
                let asActor = MessageActor(kind: user.type == .user ? .users : .unknown, id: user.id, displayName: user.name)
                return isMe(asActor)
                    ? String(localized: "summary.you.object", defaultValue: "you", comment: "You, as the object of a sentence: “Anna added you”")
                    : asActor.resolvedDisplayName
            }
            let whom = names(people, locale: locale)
            return first.systemMessage == "user_added"
                ? String(localized: "\(actor) added \(whom)", comment: "Collapsed events: someone added several people")
                : String(localized: "\(actor) removed \(whom)", comment: "Collapsed events: someone removed several people")
        }
    }

    /// Its own key: the subject of a sentence, which some languages say differently from
    /// "You" on a label (Danish: "Du", not "Dig").
    private static var you: String {
        String(localized: "summary.you.subject", defaultValue: "You", comment: "You, as the subject of a sentence: “You and Anna joined the call”")
    }

    /// "Anna", "Anna and Bo", "Anna, Bo and Carl" — then "Anna, Bo and 5 others".
    private static func names(_ names: [String], locale: Locale) -> String {
        guard names.count > 3 else { return names.formatted(.list(type: .and).locale(locale)) }
        return String(
            localized: "\(names[0]), \(names[1]) and \(names.count - 2) others",
            comment: "A list of names cut short: two names, then how many more"
        )
    }

    private static func same(_ a: MessageActor, _ b: MessageActor) -> Bool {
        a.kind == b.kind && a.id == b.id
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
        /// Two or more consecutive system events, summarised on one line.
        case systemGroup(SystemMessageGroup)
        case daySeparator(Date)
        case unreadSeparator
    }

    let id: String
    let kind: Kind

    var message: Message? {
        if case .message(let message, _) = kind { return message } else { return nil }
    }

    var isUnreadSeparator: Bool { kind == .unreadSeparator }

    /// The events a following one could join: this row's, if it is a system event or a run of them.
    private var collapsibleMessages: [Message]? {
        switch kind {
        case .message(let message, _) where message.isSystem: [message]
        case .systemGroup(let group): group.messages
        default: nil
        }
    }

    /// Builds the display list: day separators where the date changes, the unread marker
    /// where the user last left off, and grouping flags for each message.
    ///
    /// Invisible system messages (`message_deleted`, `reaction`, …) are dropped here — they
    /// exist to update the cache, not to be read. Runs of events that say one thing together
    /// — see `SystemMessageGroup` — become one row; a day or the unread marker splits a run.
    ///
    /// - Parameter isMe: whether an actor is the signed-in user, who is "You" in a summary.
    static func build(
        messages: [Message],
        firstUnreadMessageID: Int?,
        calendar: Calendar = .current,
        isMe: (MessageActor) -> Bool = { _ in false },
        locale: Locale = .current
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

            // Joins the run the row above started. Its id stays the first event's, so the
            // row that was one event keeps its identity when a second arrives.
            if let key = SystemMessageGroup.key(for: message), let last = rows.last,
               let run = last.collapsibleMessages, SystemMessageGroup.key(for: run[0]) == key {
                rows[rows.count - 1] = ChatRow(
                    id: last.id,
                    kind: .systemGroup(SystemMessageGroup(messages: run + [message], isMe: isMe, locale: locale))
                )
                previous = message
                continue
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
