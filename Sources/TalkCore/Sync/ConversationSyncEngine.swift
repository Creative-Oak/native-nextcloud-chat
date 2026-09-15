import Foundation

enum ConversationSyncEvent: Sendable {
    case conversations(ConversationListResult)
    case failed(TalkError)
    case offline(Bool)
}

/// Keeps the conversation list fresh.
///
/// The refresh policy exists because of one documented limitation: `modifiedSince` is
/// cheap but cannot tell us a conversation was deleted or that we were removed from it.
/// So: incremental on a short timer, full on a long one and on every "the user came back"
/// event. See docs/NEXTCLOUD_API.md § 4.
actor ConversationSyncEngine {
    private let service: ConversationService
    private let backoff: Backoff
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    /// How often to ask "anything new?" while the app is in use.
    var incrementalInterval: TimeInterval = 30
    /// How often to ask for everything, so removals are noticed.
    var fullRefreshInterval: TimeInterval = 5 * 60
    /// Backed right off while the app is in the background.
    var backgroundInterval: TimeInterval = 5 * 60

    private var task: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var continuation: AsyncStream<ConversationSyncEvent>.Continuation?

    private var modifiedSince: Int?
    private var lastFullRefresh: Date?
    private var isApplicationActive = true

    /// Counts the "we may have missed things" signals. A refresh records the count it set
    /// out with, so a signal that arrives while it is in flight is not credited to a
    /// response that predates it — it still gets a full refresh of its own.
    private var fullRefreshDemand = 0
    private var servedFullRefreshDemand = 0

    /// A "go now" that arrived while the loop was working rather than sleeping, kept until
    /// the loop reaches its next sleep and skips it.
    private var wakeRequested = false

    init(
        service: ConversationService,
        backoff: Backoff = .networkRetry,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.backoff = backoff
        self.sleeper = sleeper
        self.now = now
    }

    func start() -> AsyncStream<ConversationSyncEvent> {
        stop()
        let (stream, continuation) = AsyncStream<ConversationSyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        task = Task { [weak self] in await self?.run(into: continuation) }
        return stream
    }

    func stop() {
        task?.cancel()
        sleepTask?.cancel()
        task = nil
        wakeRequested = false
        continuation?.finish()
        continuation = nil
    }

    /// ⌘R, or anything else that should refresh right now.
    func refreshNow(full: Bool = false) {
        if full { fullRefreshDemand += 1 }
        wake()
    }

    /// Window activation, wake from sleep, network recovery: all of them mean "we may have
    /// missed things", so the next refresh is a full one.
    func applicationDidBecomeActive() {
        isApplicationActive = true
        fullRefreshDemand += 1
        wake()
    }

    func applicationDidResignActive() {
        isApplicationActive = false
    }

    /// Seeds the cursor from persisted state so a relaunch doesn't refetch everything.
    func seed(modifiedSince: Int?) {
        self.modifiedSince = modifiedSince
    }

    /// Cuts the current sleep short — and leaves a note in case the loop is not asleep yet.
    /// Cancelling `sleepTask` lands on nothing when the signal arrives mid-request, and the
    /// loop would then sleep out the whole interval before acting on it: ⌘R, or coming back
    /// to the app, appearing to do nothing for thirty seconds.
    private func wake() {
        wakeRequested = true
        sleepTask?.cancel()
    }

    // MARK: - The loop

    /// Writes to the continuation it was started with, never to `self.continuation` — see
    /// ``ActiveChatSyncEngine/run(token:lastKnownMessageID:into:)``. A loop cancelled while
    /// it was asleep or mid-request winds up later, and by then `self.continuation` may
    /// belong to a newer loop that this one would otherwise finish and clear.
    private func run(into continuation: AsyncStream<ConversationSyncEvent>.Continuation) async {
        var attempt = 0

        while !Task.isCancelled {
            let wantsFull = shouldFullRefresh()
            // Read here, before the request suspends us, for the same reason `wantsFull` is.
            let servingDemand = fullRefreshDemand
            do {
                let result = try await service.conversations(modifiedSince: wantsFull ? nil : modifiedSince)

                // Track the server's clock, not ours: `X-Nextcloud-Talk-Modified-Before` is
                // exactly the value the next incremental call should send.
                if let modifiedBefore = result.modifiedBefore {
                    modifiedSince = modifiedBefore
                } else if !result.conversations.isEmpty {
                    modifiedSince = result.conversations
                        .map { Int($0.lastActivity.timeIntervalSince1970) }
                        .max()
                }

                if wantsFull {
                    lastFullRefresh = now()
                    servedFullRefreshDemand = servingDemand
                }

                if attempt > 0 { continuation.yield(.offline(false)) }
                attempt = 0
                continuation.yield(.conversations(result))
            } catch {
                if Task.isCancelled { break }
                if error.requiresReauthentication {
                    continuation.yield(.failed(.unauthorized))
                    break
                }
                if error == .offline { continuation.yield(.offline(true)) }
                attempt += 1
                Log.sync.warning("Conversation refresh failed (attempt \(attempt)): \(error.userMessage)")
                await sleep(backoff.delay(forAttempt: attempt, after: error))
                continue
            }

            await sleep(currentInterval)
        }

        // Always terminate the stream. Without this, a consumer's `for await` never
        // returns after the loop stops (on a 401, say) and the task leaks for the life of
        // the process.
        continuation.finish()
    }

    private var currentInterval: TimeInterval {
        isApplicationActive ? incrementalInterval : backgroundInterval
    }

    private func shouldFullRefresh() -> Bool {
        if fullRefreshDemand > servedFullRefreshDemand { return true }
        guard let lastFullRefresh else { return true }   // first run
        return now().timeIntervalSince(lastFullRefresh) >= fullRefreshInterval
    }

    /// Interruptible sleep: `wake()` cancels it so ⌘R is instant, and it is skipped outright
    /// when the signal got here first.
    private func sleep(_ seconds: TimeInterval) async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        guard seconds > 0 else { return }
        let sleeper = self.sleeper
        let task = Task<Void, Never> { _ = try? await sleeper(seconds) }
        sleepTask = task
        await task.value
        sleepTask = nil
        wakeRequested = false
    }
}
