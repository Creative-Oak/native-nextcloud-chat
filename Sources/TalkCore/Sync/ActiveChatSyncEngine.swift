import Foundation

/// What the active-conversation sync loop reports upward.
enum ChatSyncEvent: Sendable {
    case messages(ChatBatch)
    case state(ChatSyncState)
    /// Terminal for this conversation: the caller decides what to show.
    case failed(TalkError)
}

enum ChatSyncState: Sendable, Equatable {
    case idle
    case loadingHistory
    /// Long poll is established; new messages will arrive on their own.
    case live
    case reconnecting(attempt: Int)
    case offline

    /// Waiting out a backoff rather than connected, so "the network is back" should cut the
    /// wait short. Exhaustive on purpose: a new state has to make up its mind here.
    ///
    /// `.idle` is deliberately not one of these. It is where a 401 or a deleted conversation
    /// leaves the loop, and reconnecting into those means hammering a server that already
    /// said no.
    var isRetrying: Bool {
        switch self {
        case .offline, .reconnecting: true
        case .idle, .loadingHistory, .live: false
        }
    }
}

/// Keeps one conversation up to date, using Talk's documented long poll.
///
/// Exactly one conversation is active at a time. Switching conversations cancels the
/// previous loop deterministically, which is what stops the classic bug where messages
/// from the conversation you just left arrive in the one you just opened.
actor ActiveChatSyncEngine {
    private let chat: ChatService
    private let conversations: ConversationService
    private let backoff: Backoff

    private var task: Task<Void, Never>?
    private var activeToken: String?
    private var readContext = ReadStateContext()
    private var continuation: AsyncStream<ChatSyncEvent>.Continuation?

    /// Injected so tests don't spend real seconds in backoff.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    init(
        chat: ChatService,
        conversations: ConversationService,
        backoff: Backoff = .longPoll,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.chat = chat
        self.conversations = conversations
        self.backoff = backoff
        self.sleeper = sleeper
    }

    /// Starts (or restarts) syncing `token`, resuming from `lastKnownMessageID`.
    ///
    /// - Parameter lastKnownMessageID: the newest message already in the cache. `0` means
    ///   "nothing cached", in which case a first page of history is fetched before polling.
    func activate(token: String, lastKnownMessageID: Int) -> AsyncStream<ChatSyncEvent> {
        stop()
        activeToken = token

        let (stream, continuation) = AsyncStream<ChatSyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation

        task = Task { [weak self] in
            await self?.run(token: token, lastKnownMessageID: lastKnownMessageID, into: continuation)
        }

        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
        activeToken = nil
        continuation?.finish()
        continuation = nil
    }

    /// The main actor tells us whether the user can actually see this conversation. Only
    /// when they can does the poll get permission to move the read marker.
    func setReadContext(_ context: ReadStateContext) {
        readContext = context
    }

    /// Pages further back in history. Separate from the live loop so scrolling up never
    /// disturbs polling.
    func loadOlder(token: String, before messageID: Int, limit: Int = 100) async throws(TalkError) -> ChatBatch {
        try await chat.history(token: token, lastKnownMessageID: messageID, limit: limit)
    }

    // MARK: - The loop

    /// Writes to the continuation it was started with, never to `self.continuation`.
    ///
    /// The two are the same only until the next `activate`. A cancelled loop is not stopped
    /// where it was cancelled — it is suspended in a 30-second poll, and resumes whenever
    /// that returns, which is long after the next conversation has taken `self.continuation`
    /// for its own. Finishing *that* one on the way out would have closed the new
    /// conversation's stream and left it with no sync loop at all: exactly the bug switching
    /// deterministically is meant to prevent.
    private func run(
        token: String,
        lastKnownMessageID: Int,
        into continuation: AsyncStream<ChatSyncEvent>.Continuation
    ) async {
        var cursor = lastKnownMessageID
        var attempt = 0
        var lastCommonRead: Int?

        if cursor == 0 {
            continuation.yield(.state(.loadingHistory))
            do {
                let batch = try await chat.history(token: token, limit: 100)
                cursor = batch.messages.last?.messageID ?? batch.lastGivenID ?? 0
                lastCommonRead = batch.lastCommonReadID
                continuation.yield(.messages(batch))
            } catch {
                // Credentials rejected, or the conversation is gone: there is nothing to
                // poll for, and announcing `.live` straight after a failure would be a lie.
                guard await handle(error: error, attempt: &attempt, token: token, into: continuation) else {
                    continuation.yield(.state(.idle))
                    continuation.finish()
                    return
                }
            }
        }

        continuation.yield(.state(.live))

        while !Task.isCancelled {
            do {
                let setReadMarker = ReadStatePolicy.setReadMarkerOnPoll(readContext)
                let batch = try await chat.poll(
                    token: token,
                    lastKnownMessageID: cursor,
                    timeout: 30,
                    setReadMarker: setReadMarker,
                    // Clearing Talk's own notifications is only right when the user is
                    // genuinely looking at the conversation.
                    markNotificationsAsRead: setReadMarker,
                    lastCommonReadID: lastCommonRead
                )

                if attempt > 0 {
                    attempt = 0
                    continuation.yield(.state(.live))
                }

                // 304: the poll simply timed out with nothing new. Go straight round again.
                guard !batch.isUnchanged else { continue }

                cursor = batch.lastGivenID ?? batch.messages.last?.messageID ?? cursor
                lastCommonRead = batch.lastCommonReadID ?? lastCommonRead
                continuation.yield(.messages(batch))
            } catch {
                if Task.isCancelled { break }
                let shouldContinue = await handle(error: error, attempt: &attempt, token: token, into: continuation)
                if !shouldContinue { break }
            }
        }

        continuation.yield(.state(.idle))
        continuation.finish()
    }

    /// - Returns: whether the loop should keep going.
    @discardableResult
    private func handle(
        error: TalkError,
        attempt: inout Int,
        token: String,
        into continuation: AsyncStream<ChatSyncEvent>.Continuation
    ) async -> Bool {
        switch error {
        case .cancelled:
            return false

        case .unauthorized:
            // Nothing will work until the user re-authenticates; stop rather than hammer.
            Log.sync.error("Chat sync stopped: credentials rejected")
            continuation.yield(.failed(.unauthorized))
            return false

        case .notFound:
            Log.sync.notice("Conversation \(token) is gone")
            continuation.yield(.failed(.notFound))
            return false

        case .sessionExpired:
            // 412 means the room session died. Re-join without force so another client of
            // this user (the web app, the phone) isn't kicked out from under them.
            Log.sync.info("Chat session expired for \(token); re-joining")
            _ = try? await conversations.join(token: token, force: false)
            return true

        case .offline:
            continuation.yield(.state(.offline))
            attempt += 1

        default:
            attempt += 1
            continuation.yield(.state(.reconnecting(attempt: attempt)))
            Log.sync.warning("Chat poll failed (attempt \(attempt)): \(error.userMessage)")
        }

        let delay = backoff.delay(forAttempt: attempt, after: error)
        do {
            try await sleeper(delay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
