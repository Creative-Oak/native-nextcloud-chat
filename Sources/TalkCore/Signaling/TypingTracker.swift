import Foundation

/// Who is typing in the open conversation, from the signaling server's typing messages — the
/// way Talk's own apps keep track. A session counts only while it is in the conversation, and
/// a "started" that is never followed by anything wears off: Talk repeats it every 10 seconds
/// while someone keeps typing, and forgets them 15 seconds after the last one.
struct TypingTracker: Sendable {
    static let expiry: TimeInterval = 15

    /// Someone typing, once however many of their devices are.
    struct Typist: Sendable, Hashable, Identifiable {
        var id: String
        var userID: String?
        var displayName: String?
    }

    /// This client's own signaling session and user, never shown as typing.
    var ownSessionID: String?
    var ownUserID: String?

    private(set) var sessions: [String: RoomSession] = [:]
    /// When each typing session last said so, in the order they started.
    private var started: [(session: String, at: Date)] = []

    /// A different conversation, or none: nobody is in it yet.
    mutating func reset() {
        sessions = [:]
        started = []
    }

    mutating func joined(_ list: [RoomSession]) {
        for session in list { sessions[session.signalingID] = session }
    }

    mutating func left(_ ids: [String]) {
        for id in ids { sessions[id] = nil }
        started.removeAll { ids.contains($0.session) }
    }

    /// Only from sessions known to be in the conversation, as Talk's web app has it.
    mutating func received(fromSession id: String, isTyping: Bool, at now: Date) {
        guard sessions[id] != nil else { return }
        if isTyping {
            if let index = started.firstIndex(where: { $0.session == id }) {
                started[index].at = now
            } else {
                started.append((id, now))
            }
        } else {
            started.removeAll { $0.session == id }
        }
    }

    /// The sessions a typing signal goes to: everyone in the conversation but this one.
    var recipients: [String] {
        sessions.keys.filter { $0 != ownSessionID }.sorted()
    }

    /// Who is typing at `now`, first to start first; someone on two devices is there once, and
    /// the user themselves — on another device — not at all.
    func typists(at now: Date) -> [Typist] {
        var seen = Set<String>()
        var result: [Typist] = []
        for entry in started where now.timeIntervalSince(entry.at) < Self.expiry {
            guard entry.session != ownSessionID, let session = sessions[entry.session] else { continue }
            if let user = session.userID, user == ownUserID { continue }
            let id = session.userID.map { "user:\($0)" } ?? "session:\(session.signalingID)"
            guard seen.insert(id).inserted else { continue }
            result.append(Typist(id: id, userID: session.userID, displayName: session.displayName))
        }
        return result
    }

    /// When the next typist wears off after `now`, if anyone is still typing.
    func nextExpiry(after now: Date) -> Date? {
        started.map { $0.at.addingTimeInterval(Self.expiry) }.filter { $0 > now }.min()
    }
}

/// "Heine is typing…" — worded as Talk's web app words it, cut short after three names.
enum TypingSummary {
    static func text(names: [String?]) -> String? {
        guard !names.isEmpty else { return nil }
        let known = names.compactMap { $0 }
        guard known.count == names.count else {
            return known.isEmpty || names.count == 1 ? String(localized: "Someone is typing…") : text(known: known, others: names.count - known.count)
        }
        return text(known: known, others: 0)
    }

    private static func text(known: [String], others: Int) -> String {
        let shown = Array(known.prefix(3))
        let hidden = known.count - shown.count + others
        switch (shown.count, hidden) {
        case (1, 0): return String(localized: "\(shown[0]) is typing…", comment: "%@ is a name")
        case (2, 0): return String(localized: "\(shown[0]) and \(shown[1]) are typing…", comment: "Each %@ is a name")
        case (3, 0): return String(localized: "\(shown[0]), \(shown[1]) and \(shown[2]) are typing…", comment: "Each %@ is a name")
        default:
            let list = shown.joined(separator: ", ")
            // Two whole sentences rather than a catalog plural, so the English stays right where
            // there is no catalog to pick the form (swift test).
            return hidden == 1
                ? String(localized: "\(list) and 1 other are typing…", comment: "%@ is a comma-separated list of names")
                : String(localized: "\(list) and \(hidden) others are typing…", comment: "%@ is a comma-separated list of names; the number is at least 2")
        }
    }
}
