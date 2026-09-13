import Foundation
import Testing
@testable import TalkCore

private let token = "a1b2c3d4"
private let epoch = Date(timeIntervalSince1970: 1_757_700_000)

private func message(
    _ id: Int,
    actor: String = "bob",
    text: String = "hello",
    at offset: TimeInterval = 0,
    reference: String? = nil,
    reactions: [String: Int] = [:]
) -> Message {
    Message(
        messageID: id,
        token: token,
        actor: MessageActor(kind: .users, id: actor, displayName: actor.capitalized),
        timestamp: epoch.addingTimeInterval(offset),
        text: text,
        referenceID: reference,
        reactions: reactions
    )
}

private func pending(
    text: String = "hello",
    actor: String = "alice",
    at offset: TimeInterval = 0,
    reference: String = "ref-1"
) -> Message {
    Message(
        messageID: 0,
        localID: "local-\(reference)",
        token: token,
        actor: MessageActor(kind: .users, id: actor, displayName: "Alice"),
        timestamp: epoch.addingTimeInterval(offset),
        text: text,
        referenceID: reference,
        deliveryState: .sending
    )
}

@Suite("Message timeline")
struct MessageTimelineTests {
    @Test("Messages are kept in server order regardless of arrival order")
    func ordering() {
        var timeline = MessageTimeline()
        timeline.apply([message(3), message(1), message(2)])
        #expect(timeline.messages.map(\.messageID) == [1, 2, 3])
        #expect(timeline.firstServerMessageID == 1)
        #expect(timeline.lastServerMessageID == 3)
    }

    @Test("Applying the same batch twice changes nothing")
    func idempotentMerge() {
        var timeline = MessageTimeline()
        let batch = [message(1), message(2), message(3)]
        timeline.apply(batch)
        let change = timeline.apply(batch)
        #expect(timeline.count == 3)
        #expect(change.isEmpty)
    }

    @Test("Overlapping pages don't duplicate messages")
    func overlappingPages() {
        var timeline = MessageTimeline()
        timeline.apply([message(1), message(2), message(3)])
        timeline.apply([message(3), message(4), message(5)])
        #expect(timeline.messages.map(\.messageID) == [1, 2, 3, 4, 5])
    }

    @Test("An edit updates the row in place and keeps its identity")
    func editInPlace() {
        var timeline = MessageTimeline()
        timeline.apply([message(1, text: "original")])
        let identityBefore = timeline.messages[0].localID

        var edited = message(1, text: "edited")
        edited.lastEdit = Message.EditInfo(actor: MessageActor(kind: .users, id: "bob"), timestamp: epoch)
        let change = timeline.apply([edited])

        #expect(timeline.count == 1)
        #expect(timeline.messages[0].text == "edited")
        #expect(timeline.messages[0].localID == identityBefore)
        #expect(change.updatedIDs == [identityBefore])
        #expect(change.insertedIDs.isEmpty)
    }

    @Test("A deletion replaces the message with its tombstone instead of removing the row")
    func deletionTombstone() {
        var timeline = MessageTimeline()
        timeline.apply([message(1, text: "oops")])

        var tombstone = message(1, text: "Message deleted by author")
        tombstone.kind = .commentDeleted
        tombstone.isDeleted = true
        timeline.apply([tombstone])

        #expect(timeline.count == 1)
        #expect(timeline.messages[0].isDeleted)
        #expect(timeline.messages[0].kind == .commentDeleted)
    }

    // MARK: - Optimistic sending

    @Test("A pending message sits at the end until it's acknowledged")
    func pendingSortsLast() {
        var timeline = MessageTimeline()
        timeline.apply([message(10), message(11)])
        timeline.addPending(pending())
        #expect(timeline.messages.map(\.messageID) == [10, 11, 0])
        #expect(timeline.lastServerMessageID == 11)
        #expect(timeline.pendingMessages.count == 1)
    }

    @Test("The server's echo reconciles with the pending row by reference id")
    func reconcileByReferenceID() {
        var timeline = MessageTimeline()
        let local = pending(text: "hi there", reference: "ref-abc")
        timeline.addPending(local)

        let change = timeline.apply([
            message(12, actor: "alice", text: "hi there", reference: "ref-abc")
        ])

        #expect(timeline.count == 1)                       // reconciled, not duplicated
        #expect(timeline.messages[0].messageID == 12)
        #expect(timeline.messages[0].deliveryState == .sent)
        // The row keeps its identity, so the bubble doesn't flicker on acknowledgement.
        #expect(timeline.messages[0].localID == local.localID)
        #expect(change.reconciledLocalIDs == [local.localID])
    }

    @Test("Reconciliation works whichever arrives first: the POST response or the long poll")
    func reconcileEitherOrder() {
        // Long poll first…
        var pollFirst = MessageTimeline()
        pollFirst.addPending(pending(reference: "ref-x"))
        pollFirst.apply([message(20, actor: "alice", reference: "ref-x")])
        pollFirst.apply([message(20, actor: "alice", reference: "ref-x")])   // POST response
        #expect(pollFirst.count == 1)

        // …POST response first.
        var postFirst = MessageTimeline()
        postFirst.addPending(pending(reference: "ref-y"))
        postFirst.apply([message(21, actor: "alice", reference: "ref-y")])
        postFirst.apply([message(21, actor: "alice", reference: "ref-y")])
        #expect(postFirst.count == 1)
    }

    @Test("Without reference ids, a close match still reconciles rather than duplicating")
    func reconcileWithoutReferenceID() {
        var timeline = MessageTimeline()
        timeline.addPending(pending(text: "same words", at: 0, reference: "unused"))

        // An older server echoes the message with no referenceId at all.
        var echoed = message(30, actor: "alice", text: "same words", at: 3)
        echoed.referenceID = nil
        timeline.apply([echoed])

        #expect(timeline.count == 1)
        #expect(timeline.messages[0].messageID == 30)
        #expect(timeline.messages[0].deliveryState == .sent)
    }

    @Test("The same text sent much later is a new message, not a reconciliation")
    func reconciliationWindowIsBounded() {
        var timeline = MessageTimeline()
        timeline.addPending(pending(text: "ok", at: 0, reference: "unused"))

        var muchLater = message(31, actor: "alice", text: "ok", at: MessageTimeline.reconciliationWindow + 10)
        muchLater.referenceID = nil
        timeline.apply([muchLater])

        #expect(timeline.count == 2)
    }

    @Test("Someone else's identical text never reconciles with my pending message")
    func doesNotReconcileOtherAuthors() {
        var timeline = MessageTimeline()
        timeline.addPending(pending(text: "snap", actor: "alice", reference: "unused"))

        var theirs = message(32, actor: "bob", text: "snap")
        theirs.referenceID = nil
        timeline.apply([theirs])

        #expect(timeline.count == 2)
    }

    @Test("A failed send stays visible and can be retried or removed")
    func failedSend() {
        var timeline = MessageTimeline()
        let local = pending()
        timeline.addPending(local)

        timeline.updateDeliveryState(localID: local.localID, to: .failed(reason: "Message too long"))
        #expect(timeline.messages[0].deliveryState == .failed(reason: "Message too long"))
        #expect(timeline.pendingMessages.count == 1)

        timeline.remove(localID: local.localID)
        #expect(timeline.isEmpty)
    }

    @Test("`appendedAtEnd` only fires for genuinely new messages, so history paging never yanks the scroll")
    func appendedAtEndSemantics() {
        var timeline = MessageTimeline()
        timeline.apply([message(50), message(51)])

        let older = timeline.apply([message(48), message(49)])
        #expect(older.appendedAtEnd == false)
        #expect(older.insertedIDs.count == 2)

        let newer = timeline.apply([message(52)])
        #expect(newer.appendedAtEnd)
    }

    @Test("Reactions fold into the existing message")
    func reactionUpdate() {
        var timeline = MessageTimeline()
        timeline.apply([message(60)])
        timeline.applyReactions(ReactionSummary(counts: ["👍": 2], mine: ["👍"]), toMessageID: 60)

        #expect(timeline.messages[0].reactions == ["👍": 2])
        #expect(timeline.messages[0].myReactions == ["👍"])
    }

    @Test("Lookups stay correct after inserts in the middle")
    func indexIntegrity() {
        var timeline = MessageTimeline()
        timeline.apply([message(1), message(5), message(9)])
        timeline.apply([message(3), message(7)])
        timeline.addPending(pending())

        #expect(timeline.messages.map(\.messageID) == [1, 3, 5, 7, 9, 0])
        for id in [1, 3, 5, 7, 9] {
            #expect(timeline.message(id: id)?.messageID == id)
        }
        #expect(timeline.message(localID: "local-ref-1")?.deliveryState == .sending)
    }

    @Test("A system message never reconciles with a pending user message")
    func systemMessagesDoNotReconcile() {
        var timeline = MessageTimeline()
        timeline.addPending(pending(text: "hello"))

        var system = message(70, actor: "alice", text: "hello")
        system.kind = .system
        system.systemMessage = "user_added"
        system.referenceID = nil
        timeline.apply([system])

        #expect(timeline.count == 2)
    }

    @Test("Ten thousand messages merge in a reasonable time")
    func largeTimeline() {
        var timeline = MessageTimeline()
        timeline.apply((1...10_000).map { message($0) })
        #expect(timeline.count == 10_000)

        // The hot path: one new message arriving on a big conversation.
        let change = timeline.apply([message(10_001)])
        #expect(change.insertedIDs.count == 1)
        #expect(change.appendedAtEnd)
        #expect(timeline.message(id: 5_000)?.messageID == 5_000)
    }
}
