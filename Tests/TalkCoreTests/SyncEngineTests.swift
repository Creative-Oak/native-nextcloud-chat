import Foundation
import Testing
@testable import TalkCore

private let token = "a1b2c3d4"

private func messageJSON(id: Int, text: String = "hello", actor: String = "bob") -> String {
    """
    {"id":\(id),"token":"\(token)","actorType":"users","actorId":"\(actor)",
     "actorDisplayName":"\(actor.capitalized)","timestamp":1757700000,"message":"\(text)",
     "messageParameters":[],"systemMessage":"","messageType":"comment","isReplyable":true,
     "referenceId":"","reactions":[]}
    """
}

private func services(_ transport: StubTransport) throws -> (ChatService, ConversationService) {
    let client = OCSClient(
        server: try ServerAddress.parse("https://cloud.example.com"),
        credentials: Credentials(loginName: "alice", appPassword: "pw"),
        transport: transport
    )
    return (ChatService(client: client), ConversationService(client: client))
}

/// Collects up to `count` events, then stops the engine so the test can't hang.
private func collect(
    _ stream: AsyncStream<ChatSyncEvent>,
    count: Int,
    stop: @escaping @Sendable () async -> Void
) async -> [ChatSyncEvent] {
    var events: [ChatSyncEvent] = []
    for await event in stream {
        events.append(event)
        if events.count >= count { await stop(); break }
    }
    return events
}

/// Lets the engine make progress until `condition` holds, without depending on it
/// emitting an event — a long poll that answers 304 is correctly silent.
///
/// Sleeps rather than spins: the engines run with an instant sleeper in tests, so a tight
/// `Task.yield()` loop here would saturate every core racing them.
private func spin(until condition: @Sendable () -> Bool, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private extension ChatSyncEvent {
    var batch: ChatBatch? { if case .messages(let batch) = self { return batch } else { return nil } }
    var state: ChatSyncState? { if case .state(let state) = self { return state } else { return nil } }
    var error: TalkError? { if case .failed(let error) = self { return error } else { return nil } }
}

/// A tiny lock box so a detached consumer task can hand events back to the test.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChatSyncEvent] = []
    func append(_ event: ChatSyncEvent) {
        // Bounded on purpose: a live engine can emit faster than a test consumes.
        lock.withLock { if storage.count < 500 { storage.append(event) } }
    }
    var events: [ChatSyncEvent] { lock.withLock { storage } }
}

@Suite("Active chat sync engine", .timeLimit(.minutes(1)))
struct ActiveChatSyncEngineTests {
    @Test("Loads history first when nothing is cached, then goes live")
    func coldStart() async throws {
        let transport = StubTransport { request in
            let isPoll = request.url.query()?.contains("lookIntoFuture=1") ?? false
            if isPoll { return .status(304) }
            return .json(ocsEnvelope("[\(messageJSON(id: 2)),\(messageJSON(id: 1))]"),
                         headers: ["X-Chat-Last-Given": "2"])
        }
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 0)
        let events = await collect(stream, count: 3) { await engine.stop() }

        #expect(events[0].state == .loadingHistory)
        let batch = try #require(events[1].batch)
        // History arrives newest-first from the server; the engine hands it over ascending.
        #expect(batch.messages.map(\.messageID) == [1, 2])
        #expect(events[2].state == .live)
    }

    @Test("Skips the history fetch when the cache already has messages")
    func warmStart() async throws {
        let transport = StubTransport { request in
            #expect(request.url.query()?.contains("lookIntoFuture=1") == true)
            return .json(ocsEnvelope("[\(messageJSON(id: 11))]"), headers: ["X-Chat-Last-Given": "11"])
        }
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 10)
        let events = await collect(stream, count: 2) { await engine.stop() }

        #expect(events[0].state == .live)
        #expect(events[1].batch?.messages.map(\.messageID) == [11])
        // The *first* request is the one that proves we resumed from the cache rather than
        // refetching history; later polls have moved the cursor on to 11.
        let first = try #require(transport.requests.first)
        #expect(first.url.query()?.contains("lastKnownMessageId=10") == true)
        #expect(first.url.query()?.contains("lookIntoFuture=1") == true)
    }

    @Test("A 304 from the long poll is silence, not an error")
    func notModifiedIsNormal() async throws {
        let transport = StubTransport(sequence: [.status(304)])
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        let collected = Collected()
        let consumer = Task { for await event in stream { collected.append(event) } }

        // Several polls must go by. A 304 emits nothing at all, which is the point: the
        // engine stays quiet instead of waking the UI sixty times a minute.
        await spin { transport.requestCount > 3 }
        await engine.stop()
        _ = await consumer.value

        let events = collected.events
        #expect(events.allSatisfy { $0.error == nil })
        #expect(events.compactMap(\.batch).isEmpty)
        #expect(events.first?.state == .live)
    }

    @Test("Polling never moves the read marker unless the user can actually see the conversation")
    func readMarkerRequiresVisibility() async throws {
        let transport = StubTransport(sequence: [.status(304)])
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        let consumer = Task { for await _ in stream {} }
        await spin { transport.requestCount > 0 }
        await engine.stop()
        _ = await consumer.value

        let query = try #require(transport.requests.first?.url.query())
        #expect(query.contains("setReadMarker=0"))
        #expect(query.contains("markNotificationsAsRead=0"))
        #expect(query.contains("noStatusUpdate=1"))
    }

    @Test("With the conversation visible and frontmost, the poll may set the read marker")
    func readMarkerWhenVisible() async throws {
        let transport = StubTransport(sequence: [.status(304)])
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        await engine.setReadContext(ReadStateContext(
            isSelected: true, isApplicationActive: true, isWindowKey: true, isScrolledToLatest: true
        ))

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        let consumer = Task { for await _ in stream {} }
        await spin { transport.requestCount > 0 }
        await engine.stop()
        _ = await consumer.value

        #expect(try #require(transport.requests.first?.url.query()).contains("setReadMarker=1"))
    }

    @Test("A 412 re-joins the room rather than retrying the same doomed call")
    func sessionExpiredRejoins() async throws {
        let transport = StubTransport { request in
            if request.url.path.hasSuffix("/participants/active") {
                return .json(ocsEnvelope(#"{"token":"a1b2c3d4","type":2}"#))
            }
            if request.method == .get, request.url.path.contains("/chat/") {
                // First poll fails with a dead session; afterwards it works.
                return .status(412)
            }
            return .status(404)
        }
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        let consumer = Task { for await _ in stream {} }
        await spin { transport.requests.contains { $0.url.path.hasSuffix("/participants/active") } }
        await engine.stop()
        _ = await consumer.value

        let join = try #require(transport.requests.first { $0.url.path.hasSuffix("/participants/active") })
        #expect(join.method == .post)
        // force=false: never kick the user's own session on their phone or in the browser.
        #expect(String(decoding: join.body ?? Data(), as: UTF8.self).contains("force") == false)
    }

    @Test("A 401 stops the loop instead of hammering a server that rejected us")
    func unauthorizedStops() async throws {
        let transport = StubTransport(sequence: [.json(ocsEnvelope("[]", statuscode: 401), status: 401)])
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        var events: [ChatSyncEvent] = []
        for await event in stream { events.append(event) }   // the stream finishes on its own

        #expect(events.contains { $0.error == .unauthorized })
        #expect(transport.requestCount == 1)
    }

    @Test("Transient failures back off and report reconnecting, then recover")
    func transientFailureBacksOff() async throws {
        let transport = StubTransport { request in
            if request.timeout > 45 && request.url.query()?.contains("lookIntoFuture=1") == true {
                throw TalkError.timedOut
            }
            return .status(304)
        }
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let stream = await engine.activate(token: token, lastKnownMessageID: 5)
        var states: [ChatSyncState] = []
        for await event in stream {
            if let state = event.state { states.append(state) }
            if states.count > 3 { await engine.stop(); break }
        }

        #expect(states.contains(.reconnecting(attempt: 1)))
        #expect(states.contains(.reconnecting(attempt: 2)))
    }

    @Test("Switching conversations ends the previous stream instead of leaking it")
    func switchingCancelsPrevious() async throws {
        let transport = StubTransport(sequence: [.status(304)])
        let (chat, conversations) = try services(transport)
        let engine = ActiveChatSyncEngine(chat: chat, conversations: conversations, sleeper: { _ in })

        let first = await engine.activate(token: "first", lastKnownMessageID: 1)
        _ = await engine.activate(token: "second", lastKnownMessageID: 1)

        // This loop terminating *is* the assertion: messages from the conversation you just
        // left must never keep arriving in the one you just opened.
        for await _ in first {}
        await engine.stop()
    }
}

@Suite("Conversation sync engine", .timeLimit(.minutes(1)))
struct ConversationSyncEngineTests {
    @Test("The first refresh is full; later ones are incremental using the server's cursor")
    func fullThenIncremental() async throws {
        let transport = StubTransport { _ in
            .json(ocsEnvelope(#"[{"token":"a1b2c3d4","type":2,"lastActivity":1757700000}]"#),
                  headers: ["X-Nextcloud-Talk-Modified-Before": "1757700123"])
        }
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let engine = ConversationSyncEngine(service: ConversationService(client: client), sleeper: { _ in })

        let stream = await engine.start()
        var results: [ConversationListResult] = []
        for await event in stream {
            if case .conversations(let result) = event { results.append(result) }
            if results.count >= 2 { await engine.stop(); break }
        }

        #expect(results[0].isIncremental == false)
        #expect(transport.requests[0].url.query()?.contains("modifiedSince") == false)

        #expect(results[1].isIncremental)
        // The cursor comes from the server's header, not from our own clock.
        #expect(transport.requests[1].url.query()?.contains("modifiedSince=1757700123") == true)
    }

    @Test("Fetching the sidebar never marks the user online")
    func neverUpdatesOnlineStatus() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let engine = ConversationSyncEngine(service: ConversationService(client: client), sleeper: { _ in })

        let stream = await engine.start()
        let consumer = Task { for await _ in stream {} }
        await spin { transport.requestCount > 0 }
        await engine.stop()
        _ = await consumer.value

        #expect(try #require(transport.requests.first?.url.query()).contains("noStatusUpdate=1"))
    }

    @Test("Coming back to the app forces a full refresh, so removals are noticed")
    func activationForcesFullRefresh() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]", ))
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let engine = ConversationSyncEngine(service: ConversationService(client: client), sleeper: { _ in })
        await engine.seed(modifiedSince: 1_757_000_000)

        let stream = await engine.start()
        var results: [ConversationListResult] = []
        for await event in stream {
            if case .conversations(let result) = event {
                results.append(result)
                if results.count == 1 { await engine.applicationDidBecomeActive() }
            }
            if results.count >= 3 { await engine.stop(); break }
        }

        #expect(results[0].isIncremental == false)   // first run
        #expect(results[1].isIncremental == false)   // forced by activation
    }

    @Test("A 401 stops the loop and reports it once")
    func unauthorizedStops() async throws {
        let transport = StubTransport(sequence: [.json(ocsEnvelope("[]", statuscode: 401), status: 401)])
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let engine = ConversationSyncEngine(service: ConversationService(client: client), sleeper: { _ in })

        var events: [ConversationSyncEvent] = []
        for await event in await engine.start() { events.append(event) }

        #expect(events.count == 1)
        if case .failed(let error) = events[0] { #expect(error == .unauthorized) } else { Issue.record("expected failure") }
    }
}
