import Foundation

enum ConnectionState: Sendable, Equatable {
    case online
    case offline
    /// Connectivity is back but the app hasn't yet proved the server is reachable.
    case reconnecting

    var isUsable: Bool { self != .offline }
}

/// Network reachability, behind a protocol so sync logic can be tested without a network
/// stack (and so the core keeps building where `Network` doesn't exist).
protocol NetworkMonitoring: Sendable {
    var state: ConnectionState { get async }
    /// Emits on every change, starting with the current value.
    ///
    /// `async` because the only real implementation is an actor, and an actor-isolated
    /// method cannot satisfy a nonisolated requirement under Swift 6 concurrency.
    func states() async -> AsyncStream<ConnectionState>
}

#if canImport(Network)
import Network

/// `NWPathMonitor`-backed reachability.
///
/// Note this reports *interface* reachability, not "the Nextcloud server is up" — the sync
/// engines treat it as a hint to retry sooner, never as proof of anything.
actor SystemNetworkMonitor: NetworkMonitoring {
    private let monitor = NWPathMonitor()
    private var current: ConnectionState = .online
    private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var isStarted = false

    init() {}

    var state: ConnectionState {
        get async {
            start()
            return current
        }
    }

    func states() async -> AsyncStream<ConnectionState> {
        start()
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuations[id] = continuation
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let state: ConnectionState = path.status == .satisfied ? .online : .offline
            Task { await self?.update(state) }
        }
        monitor.start(queue: DispatchQueue(label: "app.kvidr.mac.network"))
    }

    private func update(_ state: ConnectionState) {
        guard state != current else { return }
        current = state
        Log.sync.info("Network is now \(state == .online ? "online" : "offline")")
        for continuation in continuations.values { continuation.yield(state) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
#endif

/// Test double.
final class StaticNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ConnectionState
    private var continuations: [AsyncStream<ConnectionState>.Continuation] = []

    init(_ state: ConnectionState = .online) { current = state }

    var state: ConnectionState {
        get async { lock.withLock { current } }
    }

    func states() async -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        lock.withLock {
            continuations.append(continuation)
            continuation.yield(current)
        }
        return stream
    }

    func simulate(_ state: ConnectionState) {
        lock.withLock {
            current = state
            for continuation in continuations { continuation.yield(state) }
        }
    }
}
