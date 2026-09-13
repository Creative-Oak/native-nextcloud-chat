import Foundation

/// Whether a conversation's messages may be marked read.
///
/// This exists as a separate, testable decision because "read" is the single easiest thing
/// for a chat client to get wrong, and getting it wrong destroys trust in the app. The
/// rule: a message is read when the user could plausibly have *seen* it — never because
/// the client happened to download it.
struct ReadStateContext: Sendable, Equatable {
    /// This conversation is the selected one.
    var isSelected: Bool = false
    /// The app is frontmost.
    var isApplicationActive: Bool = false
    /// The window showing it is key (not just open behind something else).
    var isWindowKey: Bool = false
    /// The newest message is actually within the scroll viewport — scrolled-up history
    /// reading does not mark new arrivals read.
    var isScrolledToLatest: Bool = false
    /// The user explicitly chose Mark as Unread; nothing may undo that until they open it again.
    var userMarkedUnread: Bool = false
}

enum ReadStatePolicy {
    /// All four conditions, plus no explicit "keep it unread".
    static func canMarkRead(_ context: ReadStateContext) -> Bool {
        context.isSelected
            && context.isApplicationActive
            && context.isWindowKey
            && context.isScrolledToLatest
            && !context.userMarkedUnread
    }

    /// The read marker to send, or `nil` when nothing should be sent.
    ///
    /// - Parameters:
    ///   - latestVisibleMessageID: newest message the user could have seen.
    ///   - lastReadMessageID: what the server already believes.
    static func readMarker(
        context: ReadStateContext,
        latestVisibleMessageID: Int,
        lastReadMessageID: Int
    ) -> Int? {
        guard canMarkRead(context) else { return nil }
        guard latestVisibleMessageID > lastReadMessageID else { return nil }
        return latestVisibleMessageID
    }

    /// Whether a chat fetch may ask the server to move the read marker for us.
    ///
    /// Almost always `false`: the client decides when something has been seen, not the
    /// transport. Only a poll for the conversation the user is actively looking at may.
    static func setReadMarkerOnPoll(_ context: ReadStateContext) -> Bool {
        canMarkRead(context)
    }
}
