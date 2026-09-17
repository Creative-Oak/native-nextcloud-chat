import Foundation
import UserNotifications

/// Collapses a burst of banners into one.
///
/// Coming back from lunch to nine conversations should not be nine banners stacking up the
/// right-hand side of the screen. Past the third in a few seconds, the ones already on
/// screen are taken back and replaced by a single notification that says what is waiting —
/// written by the on-device model when there is one, and listed plainly when there isn't.
///
/// **One message still notifies instantly.** Nothing is buffered, nothing is delayed: the
/// ordinary case — a banner for a message — behaves exactly as it always has, because
/// making every notification a second late to tidy up the rare burst would be a bad trade.
@MainActor
final class NotificationDigest {
    /// What a banner was about, kept just long enough to know a burst is happening.
    private struct Entry {
        var token: String
        var identifier: String
        var who: String
        var room: String
        var isGroup: Bool
        var text: String
        var at: Date
    }

    var intelligence: OnDeviceIntelligence?
    var isEnabled = true

    private let center = UNUserNotificationCenter.current()
    private var recent: [Entry] = []
    private var summaryTask: Task<Void, Never>?

    /// A burst is this many banners inside this long.
    private static let threshold = 3
    private static let window: TimeInterval = 8
    private static let identifier = "kvidr.digest"

    /// Records a banner about to be posted, and says whether the caller should still post
    /// it. `false` means the burst has taken over and this one is part of the digest.
    func shouldPostIndividually(
        token: String,
        identifier: String,
        who: String,
        room: String,
        isGroup: Bool,
        text: String
    ) -> Bool {
        guard isEnabled else { return true }

        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > Self.window }
        recent.append(Entry(token: token, identifier: identifier, who: who, room: room,
                            isGroup: isGroup, text: text, at: now))

        // Distinct conversations, not messages: five messages in one room is what macOS's
        // own threading is for, and it already does it well.
        let rooms = Set(recent.map(\.token))
        guard rooms.count >= Self.threshold else { return true }

        collapse()
        return false
    }

    /// Nothing is waiting any more — the user opened the app, or read everything.
    func reset() {
        summaryTask?.cancel()
        recent = []
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    /// Takes back the banners already on screen and posts one in their place.
    private func collapse() {
        let entries = recent
        // The ones already delivered go; the digest stands for all of them.
        center.removeDeliveredNotifications(withIdentifiers: entries.map(\.identifier))

        // The plain version goes up straight away, so the user is never waiting on a model
        // to be told something arrived.
        post(body: Self.plainList(of: entries), count: Set(entries.map(\.token)).count)

        summaryTask?.cancel()
        guard let intelligence, intelligence.isReady else { return }
        let lines = entries.map { entry in
            let room = entry.isGroup ? " in \(entry.room)" : ""
            return "\(entry.who)\(room): \(entry.text.prefix(200))"
        }
        summaryTask = Task { [weak self] in
            guard let summary = await intelligence.notificationDigest(of: lines) else { return }
            guard !Task.isCancelled, let self, !self.recent.isEmpty else { return }
            // Posting again with the same identifier replaces what is on screen.
            self.post(body: summary, count: Set(self.recent.map(\.token)).count)
        }
    }

    private func post(body: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(count) conversations are waiting"
        content.body = body
        content.threadIdentifier = Self.identifier
        content.interruptionLevel = .passive

        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)) { error in
            if let error { Log.notification.warning("Couldn’t post the digest: \(error.localizedDescription)") }
        }
    }

    /// Without a model: who is waiting, which is the part people actually scan for.
    private static func plainList(of entries: [Entry]) -> String {
        var seen: Set<String> = []
        let names = entries.compactMap { seen.insert($0.who).inserted ? $0.who : nil }
        switch names.count {
        case 0: return "New messages"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}
