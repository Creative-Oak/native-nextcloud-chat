import Foundation

/// The ordered set of messages for one conversation, with the merge rules that keep it
/// correct no matter what order things arrive in.
///
/// This is a value type with no dependencies, which is why the awkward parts — a send that
/// the long poll echoes back before the POST returns, a deletion arriving as a
/// replacement, an edit arriving twice — are all covered by unit tests rather than by
/// hoping.
struct MessageTimeline: Sendable, Equatable {
    /// Ascending by server id; messages still in flight sort after everything acknowledged.
    private(set) var messages: [Message] = []

    /// messageID → index into `messages`, for O(1) updates on the hot path.
    private var indexByMessageID: [Int: Int] = [:]
    private var indexByLocalID: [String: Int] = [:]
    /// Local ids of messages awaiting acknowledgement. Kept separately so reconciliation
    /// scans the handful of in-flight sends rather than the whole conversation.
    private var pendingLocalIDs: [String] = []

    init(_ messages: [Message] = []) {
        apply(messages)
    }

    // MARK: - Queries

    var isEmpty: Bool { messages.isEmpty }
    var count: Int { messages.count }

    /// Highest acknowledged server id — the cursor for polling forward.
    var lastServerMessageID: Int {
        messages.last { $0.messageID > 0 }?.messageID ?? 0
    }

    /// Lowest acknowledged server id — the cursor for paging backwards.
    var firstServerMessageID: Int {
        messages.first { $0.messageID > 0 }?.messageID ?? 0
    }

    var pendingMessages: [Message] {
        pendingLocalIDs.compactMap { indexByLocalID[$0].map { messages[$0] } }
    }

    func message(id: Int) -> Message? {
        indexByMessageID[id].map { messages[$0] }
    }

    func message(localID: String) -> Message? {
        indexByLocalID[localID].map { messages[$0] }
    }

    // MARK: - Merging

    /// What a merge did, so the UI can decide whether to animate, scroll, or do nothing.
    struct Change: Sendable, Equatable {
        var insertedIDs: [String] = []
        var updatedIDs: [String] = []
        /// True when at least one message arrived *after* everything we already had, which
        /// is the only case where following the scroll to the bottom makes sense.
        var appendedAtEnd = false
        /// Messages that were acknowledged by the server during this merge.
        var reconciledLocalIDs: [String] = []

        var isEmpty: Bool { insertedIDs.isEmpty && updatedIDs.isEmpty }
    }

    /// Merges a batch of server messages.
    ///
    /// Ordering, de-duplication and optimistic reconciliation all happen here:
    /// - a message already known by id is *updated in place* (edits, reactions, tombstones)
    /// - a message matching a pending local message is *reconciled* rather than duplicated
    /// - anything else is inserted at its sorted position
    @discardableResult
    mutating func apply(_ incoming: [Message]) -> Change {
        var change = Change()
        let previousHighest = lastServerMessageID

        var insertions: [Message] = []

        for message in incoming {
            if let existing = indexByMessageID[message.messageID], message.messageID > 0 {
                // Preserve the local identity we already gave this row so SwiftUI doesn't
                // tear it down and rebuild it just because the text changed.
                var merged = message
                merged.localID = messages[existing].localID
                merged.deliveryState = .sent
                if messages[existing] != merged {
                    messages[existing] = merged
                    change.updatedIDs.append(merged.localID)
                }
                continue
            }

            if let pendingIndex = pendingMatch(for: message) {
                var merged = message
                // Keep the pending row's identity: the bubble on screen stays the same
                // view, it just stops being pending.
                merged.localID = messages[pendingIndex].localID
                merged.deliveryState = .sent
                change.reconciledLocalIDs.append(merged.localID)
                change.updatedIDs.append(merged.localID)
                messages[pendingIndex] = merged
                pendingLocalIDs.removeAll { $0 == merged.localID }
                // The row is acknowledged now, so it has to move from the pending tail into
                // its place in server order.
                resort()
                continue
            }

            insertions.append(message)
            change.insertedIDs.append(message.localID)
        }

        if !insertions.isEmpty {
            // One sort for the whole batch: paging in 10 000 messages must not be O(n²).
            messages.append(contentsOf: insertions)
            resort()
        }

        change.appendedAtEnd = lastServerMessageID > previousHighest
        return change
    }

    /// Adds a locally-created message that the server hasn't acknowledged yet.
    mutating func addPending(_ message: Message) {
        precondition(message.messageID == 0, "A pending message must not claim a server id")
        messages.append(message)
        pendingLocalIDs.append(message.localID)
        indexByLocalID[message.localID] = messages.count - 1
    }

    mutating func updateDeliveryState(localID: String, to state: MessageDeliveryState) {
        guard let index = indexByLocalID[localID] else { return }
        messages[index].deliveryState = state
        if !state.isPending { pendingLocalIDs.removeAll { $0 == localID } }
    }

    mutating func remove(localID: String) {
        guard let index = indexByLocalID[localID] else { return }
        messages.remove(at: index)
        pendingLocalIDs.removeAll { $0 == localID }
        reindex()
    }

    /// Applies a reaction summary from the reaction API to one message.
    mutating func applyReactions(_ summary: ReactionSummary, toMessageID messageID: Int) {
        guard let index = indexByMessageID[messageID] else { return }
        messages[index].reactions = summary.counts
        messages[index].myReactions = summary.mine
    }

    /// Drops everything, e.g. when the conversation's history was cleared server-side.
    mutating func removeAll() {
        messages = []
        indexByMessageID = [:]
        indexByLocalID = [:]
        pendingLocalIDs = []
    }

    // MARK: - Private

    /// Finds the pending message that this server message is the acknowledgement of.
    ///
    /// `referenceId` is exact and is what we use whenever the server supports it. The
    /// fallback — same author, same text, close in time — exists for servers without
    /// `chat-reference-id`, where the alternative is a visible duplicate.
    private func pendingMatch(for message: Message) -> Int? {
        guard !message.isSystem, !pendingLocalIDs.isEmpty else { return nil }
        let candidates = pendingLocalIDs.compactMap { indexByLocalID[$0] }

        if let reference = message.referenceID, !reference.isEmpty,
           let index = candidates.first(where: { messages[$0].referenceID == reference }) {
            return index
        }

        return candidates.first { index in
            let candidate = messages[index]
            return candidate.actor.id == message.actor.id
                && candidate.text == message.text
                && abs(candidate.timestamp.timeIntervalSince(message.timestamp)) <= Self.reconciliationWindow
        }
    }

    /// How far apart a local send and the server's timestamp may be and still be the same
    /// message, when no reference id is available. Generous enough for clock skew, tight
    /// enough that re-sending the same text tomorrow doesn't collapse into one row.
    static let reconciliationWindow: TimeInterval = 90

    /// Total order: acknowledged messages by server id, then anything still in flight by
    /// the time it was composed. Deterministic, so equal inputs always produce equal output.
    static func isOrderedBefore(_ a: Message, _ b: Message) -> Bool {
        let aPending = a.deliveryState.isPending
        let bPending = b.deliveryState.isPending
        if aPending != bPending { return !aPending }
        if aPending {
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.localID < b.localID
        }
        if a.messageID != b.messageID { return a.messageID < b.messageID }
        return a.localID < b.localID
    }

    private mutating func resort() {
        messages.sort(by: Self.isOrderedBefore)
        reindex()
    }

    private mutating func reindex() {
        indexByMessageID.removeAll(keepingCapacity: true)
        indexByLocalID.removeAll(keepingCapacity: true)
        indexByMessageID.reserveCapacity(messages.count)
        indexByLocalID.reserveCapacity(messages.count)
        for index in messages.indices {
            let message = messages[index]
            if message.messageID > 0 { indexByMessageID[message.messageID] = index }
            indexByLocalID[message.localID] = index
        }
    }
}
