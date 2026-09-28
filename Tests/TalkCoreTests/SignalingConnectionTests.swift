import Foundation
import Testing
@testable import TalkCore

// MARK: - A scripted signaling server

private actor FakeSocket {
    private var buffered: [Data] = []
    private var waiters: [CheckedContinuation<Data, any Error>] = []
    private(set) var isClosed = false
    private(set) var sent: [Data] = []

    func deliver(_ json: String) {
        let data = Data(json.utf8)
        if waiters.isEmpty { buffered.append(data) } else { waiters.removeFirst().resume(returning: data) }
    }

    func receive() async throws -> Data {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if isClosed { throw WebSocketError.closed }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func record(_ data: Data) { sent.append(data) }

    func close() {
        isClosed = true
        for waiter in waiters { waiter.resume(throwing: WebSocketError.closed) }
        waiters.removeAll()
    }

    /// Answers once the socket is closed — a ping that is never answered while it's open.
    func waitUntilClosed() async throws {
        while !isClosed { try await Task.sleep(for: .milliseconds(5)) }
        throw WebSocketError.closed
    }
}

private struct FakeChannel: WebSocketChannel {
    let socket: FakeSocket
    let onSend: @Sendable (FakeSocket, [String: Any]) async -> Void

    func send(_ data: Data) async throws {
        await socket.record(data)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        nonisolated(unsafe) let message = object
        await onSend(socket, message)
    }
    func receive() async throws -> Data { try await socket.receive() }
    func ping() async throws { try await socket.waitUntilClosed() }
    func close() { Task { await socket.close() } }
}

private final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakeSocket] = []
    let script: @Sendable (Int, FakeSocket, [String: Any]) async -> Void
    let welcome: String

    init(welcome: String = #"{"type":"welcome","welcome":{"features":["hello-v2"]}}"#,
         script: @escaping @Sendable (Int, FakeSocket, [String: Any]) async -> Void) {
        self.welcome = welcome
        self.script = script
    }

    var sockets: [FakeSocket] { lock.withLock { opened } }

    func open(_ url: URL) -> any WebSocketChannel {
        let socket = FakeSocket()
        let index = lock.withLock { opened.append(socket); return opened.count - 1 }
        let welcome = self.welcome
        Task { await socket.deliver(welcome) }
        let script = self.script
        return FakeChannel(socket: socket) { socket, message in await script(index, socket, message) }
    }
}

private let authURL = URL(string: "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v3/signaling/backend")!

private func external(token: String = "jwt") -> SignalingSettings {
    SignalingSettings(mode: "external", server: "https://signal.example.com/standalone-signaling/", userID: "alice", helloToken: token, ticket: "t")
}

private func connection(_ transport: FakeTransport, settings: SignalingSettings = external()) -> SignalingConnection {
    SignalingConnection(
        settings: { settings },
        authURL: authURL,
        transport: transport,
        sleeper: { _ in try await Task.sleep(for: .milliseconds(1)) },
        backoff: { _ in .zero }
    )
}

private func wait(for connection: SignalingConnection, until matches: @escaping @Sendable (SignalingConnection.State) -> Bool) async throws {
    try await withTimeout(.seconds(5)) {
        for await state in await connection.states() where matches(state) { return }
    }
}

private func hello(_ message: [String: Any]) -> [String: Any]? { message["hello"] as? [String: Any] }

// MARK: - Tests

@Suite("Signaling connection")
struct SignalingConnectionTests {
    @Test("The websocket is the server's address as wss, with /spreed on the end — and only a secure one")
    func websocketURL() {
        #expect(external().websocketURL?.absoluteString == "wss://signal.example.com/standalone-signaling/spreed")
        var plain = external()
        plain.server = "http://signal.example.com"
        #expect(plain.websocketURL == nil)
    }

    @Test("Signaling settings decode, including the 2.0 token")
    func decodesSettings() throws {
        let json = #"{"signalingMode":"external","server":"https://signal.example.com/","userId":"alice","ticket":"abc","helloAuthParams":{"1.0":{"userid":"alice","ticket":"abc"},"2.0":{"token":"eyJ"}},"stunservers":[],"turnservers":[],"hideWarning":false,"sipDialinInfo":"","federation":null}"#
        let settings = try JSONDecoder().decode(SignalingSettingsDTO.self, from: Data(json.utf8)).model()
        #expect(settings.isExternal)
        #expect(settings.helloToken == "eyJ")
        #expect(settings.ticket == "abc")
    }

    @Test("It signs in with the 2.0 token once the server offers it, and is connected")
    func signsIn() async throws {
        let transport = FakeTransport { _, socket, message in
            if hello(message) != nil {
                await socket.deliver(#"{"id":"1","type":"hello","hello":{"sessionid":"s1","resumeid":"r1","userid":"alice","version":"2.0"}}"#)
            }
        }
        let signaling = connection(transport)
        await signaling.start()
        try await wait(for: signaling) { $0 == .connected(sessionID: "s1") }

        let sent = try #require(await transport.sockets.first?.sent.first)
        let object = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let body = try #require(hello(object))
        #expect(body["version"] as? String == "2.0")
        #expect(body["features"] as? [String] == ["chat-relay"])
        let auth = try #require(body["auth"] as? [String: Any])
        #expect(auth["url"] as? String == authURL.absoluteString)
        #expect((auth["params"] as? [String: String])?["token"] == "jwt")
        await signaling.stop()
    }

    @Test("A dropped connection comes back by resuming the same session")
    func resumes() async throws {
        let transport = FakeTransport { index, socket, message in
            guard let body = hello(message) else { return }
            if body["resumeid"] as? String == "r1" {
                await socket.deliver(#"{"type":"hello","hello":{"sessionid":"s1","version":"2.0"}}"#)
            } else {
                await socket.deliver(#"{"type":"hello","hello":{"sessionid":"s1","resumeid":"r1","version":"2.0"}}"#)
                if index == 0 { Task { try? await Task.sleep(for: .milliseconds(50)); await socket.close() } }
            }
        }
        let signaling = connection(transport)
        await signaling.start()
        try await wait(for: signaling) { $0 == .reconnecting }
        try await wait(for: signaling) { $0 == .connected(sessionID: "s1") }

        #expect(transport.sockets.count == 2)
        let second = try #require(await transport.sockets[1].sent.first)
        let object = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        #expect(hello(object)?["resumeid"] as? String == "r1")
        await signaling.stop()
    }

    @Test("A resume the server refuses is followed by a fresh sign-in")
    func freshAfterRefusedResume() async throws {
        let transport = FakeTransport { index, socket, message in
            guard let body = hello(message) else { return }
            if body["resumeid"] != nil {
                await socket.deliver(#"{"type":"error","error":{"code":"no_such_session","message":"gone"}}"#)
            } else if index == 0 {
                await socket.deliver(#"{"type":"hello","hello":{"sessionid":"s1","resumeid":"r1","version":"2.0"}}"#)
                Task { try? await Task.sleep(for: .milliseconds(50)); await socket.close() }
            } else {
                await socket.deliver(#"{"type":"hello","hello":{"sessionid":"s2","resumeid":"r2","version":"2.0"}}"#)
            }
        }
        let signaling = connection(transport)
        await signaling.start()
        try await wait(for: signaling) { $0 == .connected(sessionID: "s2") }
        await signaling.stop()
    }

    @Test("A server without a High Performance Backend isn't connected to at all")
    func internalSignaling() async throws {
        let transport = FakeTransport { _, _, _ in }
        var settings = external()
        settings.mode = "internal"
        let signaling = connection(transport, settings: settings)
        await signaling.start()
        try await wait(for: signaling) { if case .unavailable = $0 { true } else { false } }
        #expect(transport.sockets.isEmpty)
    }

    @Test("Reconnecting waits 1, 2, 4… up to 16 seconds, give or take half")
    func backoff() {
        #expect(SignalingConnection.backoff(afterFailures: 1, random: 0.5) == .seconds(1))
        #expect(SignalingConnection.backoff(afterFailures: 3, random: 0.5) == .seconds(4))
        #expect(SignalingConnection.backoff(afterFailures: 9, random: 0.5) == .seconds(16))
        #expect(SignalingConnection.backoff(afterFailures: 5, random: 0) == .seconds(8))
    }

    @Test("Messages encode as the protocol expects")
    func encoding() throws {
        let resume = try #require(try JSONSerialization.jsonObject(with: SignalingOutbound.resume(id: "4", resumeID: "r").encoded()) as? [String: Any])
        #expect(resume["type"] as? String == "hello")
        #expect(hello(resume)?["resumeid"] as? String == "r")
        #expect(SignalingInbound.decode(Data(#"{"type":"event","event":{"target":"roomlist"}}"#.utf8)).map {
            if case .other(let type, _) = $0 { type == "event" } else { false }
        } == true)
    }

    @Test("Conversation events are sorted by what changed")
    func decodesEvents() {
        func decode(_ json: String) -> SignalingInbound? { SignalingInbound.decode(Data(json.utf8)) }
        #expect(decode(#"{"type":"event","event":{"target":"roomlist","type":"invite","invite":{"roomid":"abc","properties":{}}}}"#) == .roomList(.added, token: "abc"))
        #expect(decode(#"{"type":"event","event":{"target":"roomlist","type":"disinvite","disinvite":{"roomid":"abc"}}}"#) == .roomList(.removed, token: "abc"))
        #expect(decode(#"{"type":"event","event":{"target":"roomlist","type":"update","update":{"roomid":"abc","properties":{"name":"New"}}}}"#) == .roomList(.updated, token: "abc"))
        #expect(decode(#"{"type":"event","event":{"target":"roomlist","type":"delete","delete":{"roomid":"abc"}}}"#) == .roomList(.deleted, token: "abc"))
        #expect(decode(#"{"type":"event","event":{"target":"participants","type":"update","update":{"roomid":"abc","users":[]}}}"#) == .participantsChanged(token: "abc", users: [], everyone: nil))
        #expect(decode(#"{"type":"event","event":{"target":"room","type":"message","message":{"roomid":"abc","data":{"type":"chat","chat":{"refresh":true}}}}}"#) == .roomMessage(token: "abc"))
        #expect(decode(#"{"type":"room","room":{"roomid":"abc","properties":{}}}"#) == .room(roomID: "abc"))
        // Breakout rooms starting or stopping move the session.
        #expect(decode(#"{"type":"event","event":{"target":"room","type":"switchto","switchto":{"roomid":"room2"}}}"#) == .switchTo(token: "room2"))
    }

    @Test("The conversation it should be in is joined on sign-in, and again after a fresh one")
    func joinsRoom() async throws {
        let transport = FakeTransport { index, socket, message in
            guard let body = hello(message) else { return }
            if body["resumeid"] != nil {
                await socket.deliver(#"{"type":"error","error":{"code":"no_such_session","message":"gone"}}"#)
                return
            }
            await socket.deliver(#"{"type":"hello","hello":{"sessionid":"s\#(index)","resumeid":"r","version":"2.0"}}"#)
            if index == 0 { Task { try? await Task.sleep(for: .milliseconds(80)); await socket.close() } }
        }
        let signaling = connection(transport)
        await signaling.join(roomID: "abc", sessionID: "nc-session")
        await signaling.start()
        try await wait(for: signaling) { $0 == .connected(sessionID: "s1") }
        try await Task.sleep(for: .milliseconds(30))

        for socket in transport.sockets {
            let rooms = await socket.sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .compactMap { $0["room"] as? [String: String] }
            #expect(rooms == [["roomid": "abc", "sessionid": "nc-session"]])
        }
        await signaling.stop()
    }
}
