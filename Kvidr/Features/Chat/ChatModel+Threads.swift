import Foundation

/// Starting threads, the list of them, renaming, and how much each one notifies. Reading
/// and posting in an open thread is in `ChatModel` itself, beside the rows it decides.
extension ChatModel {
    // MARK: - Starting one

    /// Whether the composer can start a thread: not inside one, not while editing.
    var canCreateThread: Bool {
        capabilities.supportsThreads && conversation.canPostMessages && openThread == nil && editing == nil
    }

    var trimmedThreadTitle: String? {
        guard let title = newThreadTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// A title line in the composer; what is sent next starts the thread, as its first message.
    func beginNewThread() {
        guard canCreateThread else { return }
        replyingTo = nil
        newThreadTitle = newThreadTitle ?? ""
    }

    func cancelNewThread() {
        newThreadTitle = nil
    }

    // MARK: - The list

    func loadThreads() async {
        guard capabilities.supportsThreads else { return }
        do throws(TalkError) {
            threads = try await session.threads.recent(token: token)
        } catch {
            Log.chat.info("Couldn’t load threads: \(error.userMessage)")
        }
    }

    /// Fresh details of one thread — its notification level, say — into the list.
    func refreshThread(_ id: Int) async {
        guard capabilities.supportsThreads else { return }
        do throws(TalkError) {
            upsert(try await session.threads.thread(token: token, id: id))
        } catch {
            Log.chat.info("Couldn’t load the thread: \(error.userMessage)")
        }
    }

    /// A thread in the messages that the list hasn't got — someone just started it — has the
    /// list fetched again, once per thread.
    func noticeNewThreads() {
        guard capabilities.supportsThreads else { return }
        let known = Set(threads.map(\.id))
        let new = Set(threadReplyCounts.keys).subtracting(known).subtracting(threadsAskedAbout)
        guard !new.isEmpty else { return }
        threadsAskedAbout.formUnion(new)
        Task { await loadThreads() }
    }

    func threadSummary(_ id: Int) -> ThreadSummary? {
        threads.first { $0.id == id }
    }

    func notificationLevel(ofThread id: Int) -> ThreadNotificationLevel {
        threadSummary(id)?.notificationLevel ?? .default
    }

    // MARK: - Renaming

    /// Its author and moderators may; when who started it isn't known here, the server says.
    func canRenameThread(_ thread: MessageThread) -> Bool {
        guard capabilities.supportsThreads else { return false }
        if conversation.isModerator { return true }
        let root = timeline.message(id: thread.id) ?? threadHistory.values.first { $0.messageID == thread.id }
            ?? threadSummary(thread.id)?.first
        return root.map { session.account.isMe($0.actor) } ?? true
    }

    func renameThread(_ thread: MessageThread, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != thread.title else { return }
        let session = self.session
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                let renamed = try await session.threads.rename(token: token, id: thread.id, title: title)
                self?.upsert(renamed)
                self?.retitle(thread.id, to: renamed.title)
            } catch {
                self?.lastError = error
            }
        }
    }

    /// The new title on every copy of the thread's messages here, and on the open thread.
    private func retitle(_ id: Int, to title: String) {
        let retitled = timeline.messages.compactMap { message -> Message? in
            guard message.thread?.id == id else { return nil }
            var message = message
            message.thread?.title = title
            return message
        }
        for (key, var message) in threadHistory where message.thread?.id == id {
            message.thread?.title = title
            threadHistory[key] = message
        }
        if openThread?.id == id { openThread?.title = title }
        if retitled.isEmpty {
            rebuildRows()
        } else {
            mutateTimeline { _ = $0.apply(retitled) }
        }
    }

    // MARK: - Notifications

    func setNotificationLevel(_ level: ThreadNotificationLevel, forThread id: Int) {
        let session = self.session
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                self?.upsert(try await session.threads.setNotificationLevel(level, token: token, id: id))
            } catch {
                self?.lastError = error
            }
        }
    }

    private func upsert(_ summary: ThreadSummary) {
        if let index = threads.firstIndex(where: { $0.id == summary.id }) {
            threads[index] = summary
        } else {
            threads.append(summary)
        }
        threads.sort { $0.lastActivity > $1.lastActivity }
    }
}
