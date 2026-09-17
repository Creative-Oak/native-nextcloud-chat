import Foundation

/// Asks Nextcloud for the user's notifications every half minute while kvidr runs.
///
/// Two things come of it. A new mention or message anywhere starts a conversation refresh at
/// once, instead of waiting out the five minutes kvidr otherwise leaves between checks while
/// it's in the background — the banner itself is still raised by the refresh, so nothing is
/// announced twice. And a call gets a banner of its own, which nothing else in kvidr would
/// raise.
///
/// The list is fetched with its `ETag`, so asking when nothing changed is a `304` and next to
/// free. Reminders are left alone: macOS already has those scheduled.
@MainActor
final class NotificationPoller {
    struct Handlers {
        var chatActivity: () -> Void
        var callStarted: (ServerNotification) -> Void
        /// Notifications that are no longer on the server — a call answered, ended or missed.
        var gone: (Set<Int>) -> Void
    }

    private let service: NotificationsService
    private let handlers: Handlers
    private var task: Task<Void, Never>?
    private var etag: String?
    /// What was on the list last time. Nil until the first answer, which only sets the baseline:
    /// what was there before kvidr looked isn't news.
    private var known: Set<Int>?

    private static let interval: Duration = .seconds(30)
    private static let retryInterval: Duration = .seconds(90)

    init(service: NotificationsService, handlers: Handlers) {
        self.service = service
        self.handlers = handlers
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.poll()
                guard let pause else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One look. Answers how long to wait before the next, or nil to stop asking.
    private func poll() async -> Duration? {
        do throws(TalkError) {
            switch try await service.notifications(etag: etag) {
            case .unavailable:
                Log.notification.info("No notifications app on this server; not polling it")
                return nil
            case .unchanged:
                return Self.interval
            case .changed(let items, let newETag):
                etag = newETag
                apply(items)
                return Self.interval
            }
        } catch .cancelled {
            return nil
        } catch {
            Log.notification.warning("Couldn’t check notifications: \(error.userMessage)")
            return Self.retryInterval
        }
    }

    private func apply(_ items: [ServerNotification]) {
        let current = Set(items.map(\.id))
        defer { known = current }
        guard let known else { return }

        let gone = known.subtracting(current)
        if !gone.isEmpty { handlers.gone(gone) }

        let fresh = items.filter { !known.contains($0.id) }
        if fresh.contains(where: { if case .chat = $0.kind { true } else if case .invitation = $0.kind { true } else { false } }) {
            handlers.chatActivity()
        }
        for item in fresh {
            if case .call = item.kind { handlers.callStarted(item) }
        }
    }
}
