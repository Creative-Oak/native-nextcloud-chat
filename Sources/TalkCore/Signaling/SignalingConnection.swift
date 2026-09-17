import Foundation

/// A lasting connection to the High Performance Backend, signed in as this user.
///
/// This is the foundation only: it connects, signs in, notices a dead socket and comes back —
/// resuming the same session where the server still has it, signing in afresh where it
/// doesn't. What travels over it (instant updates, typing) is built on top.
///
/// Nextcloud's app password never goes to the signaling server, which may well be another
/// host: signing in uses the short-lived token Nextcloud hands out in its signaling settings.
actor SignalingConnection {
    enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected(sessionID: String)
        /// Lost, and trying again after a pause.
        case reconnecting
        /// Nothing to connect to: no High Performance Backend, or one kvidr won't use.
        case unavailable(String)
    }

    private let settings: @Sendable () async throws(TalkError) -> SignalingSettings
    private let authURL: URL
    private let transport: any WebSocketTransport
    private let sleeper: @Sendable (Duration) async throws -> Void

    private(set) var state: State = .idle {
        didSet { if state != oldValue { for continuation in stateContinuations.values { continuation.yield(state) } } }
    }
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var inboundContinuations: [UUID: AsyncStream<SignalingInbound>.Continuation] = [:]

    private var loop: Task<Void, Never>?
    private var channel: (any WebSocketChannel)?
    private var resumeID: String?
    private var nextID = 1
    private var wakeRequested = false
    /// The conversation to be in, and the Nextcloud session to be in it with. Sent again after
    /// every fresh sign-in; a resumed session is still in it.
    private var desiredRoom: (roomID: String, sessionID: String)?
    private let backoff: @Sendable (Int) -> Duration

    static let pingInterval: Duration = .seconds(30)
    static let pingTimeout: Duration = .seconds(10)
    static let welcomeTimeout: Duration = .seconds(3)
    static let helloTimeout: Duration = .seconds(10)

    init(
        settings: @escaping @Sendable () async throws(TalkError) -> SignalingSettings,
        authURL: URL,
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        backoff: @escaping @Sendable (Int) -> Duration = { SignalingConnection.backoff(afterFailures: $0) }
    ) {
        self.settings = settings
        self.authURL = authURL
        self.transport = transport
        self.sleeper = sleeper
        self.backoff = backoff
    }

    /// Every state change, starting with the current one.
    func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stateContinuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeStateContinuation(id) } }
        return stream
    }

    /// Everything the server sends once signed in, for the features built on this.
    func inbound() -> AsyncStream<SignalingInbound> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SignalingInbound>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inboundContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeInboundContinuation(id) } }
        return stream
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    /// Signs out for good: tells the server so it can drop the session, and stops.
    func stop() async {
        loop?.cancel()
        loop = nil
        if let channel {
            try? await channel.send(SignalingOutbound.bye(id: makeID()).encoded())
            channel.close()
        }
        channel = nil
        resumeID = nil
        state = .idle
    }

    /// Joins a conversation on the signaling server, leaving whichever it was in. The session
    /// is Nextcloud's, from joining the conversation there first.
    func join(roomID: String, sessionID: String) async {
        desiredRoom = (roomID, sessionID)
        guard case .connected = state, let channel else { return }
        try? await channel.send(SignalingOutbound.room(id: makeID(), roomID: roomID, sessionID: sessionID).encoded())
    }

    /// Leaves the conversation it is in, if any.
    func leaveRoom() async {
        let had = desiredRoom
        desiredRoom = nil
        guard had != nil, case .connected = state, let channel else { return }
        try? await channel.send(SignalingOutbound.room(id: makeID(), roomID: "", sessionID: "").encoded())
    }

    /// The Mac woke, or the network came back: don't wait out the pause, and drop a socket
    /// that may have died while nobody was looking.
    func reconnectNow() {
        if case .connected = state {
            channel?.close()
        }
        wakeRequested = true
    }

    // MARK: - The loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            state = failures == 0 ? .connecting : .reconnecting
            do {
                try await connectAndServe(onSignedIn: { failures = 0 })
            } catch let unavailable as Unavailable {
                state = .unavailable(unavailable.reason)
                return
            } catch {
                Log.sync.info("Signaling connection ended: \(String(describing: error))")
            }
            channel?.close()
            channel = nil
            guard !Task.isCancelled else { return }
            failures += 1
            state = .reconnecting
            await pause(backoff(failures))
        }
    }

    private struct Unavailable: Error { let reason: String }
    private struct Refused: Error { let code: String }

    /// One connection, from opening the socket until it drops.
    private func connectAndServe(onSignedIn: () -> Void) async throws {
        // A resume needs nothing new from Nextcloud; a fresh sign-in needs a fresh token.
        let current: SignalingSettings
        do {
            current = try await settings()
        } catch {
            throw error
        }
        guard current.isExternal else {
            throw Unavailable(reason: "This server uses Talk’s built-in signaling")
        }
        guard let url = current.websocketURL else {
            throw Unavailable(reason: "The signaling server isn’t on a secure address")
        }

        let channel = transport.open(url)
        self.channel = channel

        // The server introduces itself first, and says whether it takes the 2.0 sign-in.
        var features: [String] = []
        if case .welcome(let offered)? = try? await withTimeout(Self.welcomeTimeout, { try await Self.receive(channel) }) {
            features = offered
        }

        let sessionID: String
        var resumed = false
        if let resumeID, let result = try? await hello(.resume(id: makeID(), resumeID: resumeID), on: channel) {
            sessionID = result.sessionID
            resumed = true
        } else {
            resumeID = nil
            let request: SignalingOutbound
            if features.contains("hello-v2"), let token = current.helloToken {
                request = .hello(id: makeID(), version: "2.0", authURL: authURL, params: ["token": token], features: ["chat-relay"])
            } else if let ticket = current.ticket {
                request = .hello(
                    id: makeID(), version: "1.0", authURL: authURL,
                    params: ["userid": current.userID ?? "", "ticket": ticket], features: ["chat-relay"]
                )
            } else {
                throw Unavailable(reason: "Nextcloud gave no way to sign in to the signaling server")
            }
            let signedIn = try await hello(request, on: channel)
            sessionID = signedIn.sessionID
            resumeID = signedIn.resumeID
        }

        state = .connected(sessionID: sessionID)
        onSignedIn()

        // A new session isn't in any conversation yet.
        if !resumed, let desiredRoom {
            try? await channel.send(SignalingOutbound.room(id: makeID(), roomID: desiredRoom.roomID, sessionID: desiredRoom.sessionID).encoded())
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.keepAlive(channel) }
            group.addTask { try await self.receiveLoop(channel) }
            // Whichever ends first — a failed ping or a closed socket — ends the connection.
            try await group.next()
            group.cancelAll()
        }
    }

    private func hello(_ request: SignalingOutbound, on channel: any WebSocketChannel) async throws -> (sessionID: String, resumeID: String?) {
        try await channel.send(request.encoded())
        return try await withTimeout(Self.helloTimeout) {
            while true {
                switch try await Self.receive(channel) {
                case .hello(_, let session, let resume, _):
                    return (session, resume)
                case .error(_, let code, _):
                    throw Refused(code: code)
                default:
                    continue
                }
            }
        }
    }

    private func receiveLoop(_ channel: any WebSocketChannel) async throws {
        while !Task.isCancelled {
            let message = try await Self.receive(channel)
            if case .bye = message { throw WebSocketError.closed }
            publish(message)
        }
    }

    private func keepAlive(_ channel: any WebSocketChannel) async throws {
        while !Task.isCancelled {
            try await sleeper(Self.pingInterval)
            try await withTimeout(Self.pingTimeout) { try await channel.ping() }
        }
    }

    private static func receive(_ channel: any WebSocketChannel) async throws -> SignalingInbound {
        while true {
            let data = try await channel.receive()
            if let message = SignalingInbound.decode(data) { return message }
        }
    }

    // MARK: - Helpers

    /// 1 s, 2 s, 4 s… up to 16 s, each somewhere between half and one and a half of that, so a
    /// server coming back isn't met by every client at once — as Talk's web app waits.
    static func backoff(afterFailures failures: Int, random: Double = Double.random(in: 0...1)) -> Duration {
        let base = min(pow(2, Double(max(failures - 1, 0))), 16)
        return .milliseconds(Int((base * (0.5 + random)) * 1000))
    }

    /// Waits out the pause in short steps, so a wake from sleep or a network change can cut it
    /// short — see ``reconnectNow()``.
    private func pause(_ duration: Duration) async {
        wakeRequested = false
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while clock.now < deadline, !wakeRequested, !Task.isCancelled {
            try? await sleeper(min(.milliseconds(250), deadline - clock.now))
        }
        wakeRequested = false
    }

    private func publish(_ message: SignalingInbound) {
        for continuation in inboundContinuations.values { continuation.yield(message) }
    }

    private func makeID() -> String {
        defer { nextID += 1 }
        return String(nextID)
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeInboundContinuation(_ id: UUID) { inboundContinuations[id] = nil }
}

/// Runs `operation`, or throws `WebSocketError.timedOut` if it takes longer than `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw WebSocketError.timedOut
        }
        guard let result = try await group.next() else { throw WebSocketError.timedOut }
        group.cancelAll()
        return result
    }
}
