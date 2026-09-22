import Foundation

/// Typing indicators over the High Performance Backend, both ways, for the conversation this
/// client is in on the signaling server.
///
/// Sending works as Talk's web app sends: "started" to everyone in the conversation at the
/// first keystroke, again every 10 seconds while the typing goes on, and "stopped" once a
/// 10-second stretch passes with none, or the text is sent or cleared. Only when the user's
/// typing privacy is public — which also decides whether others' typing is shown, as in Talk.
@MainActor
final class LiveTyping {
    static let beat: Duration = .seconds(10)

    /// Who is typing in ``room``, whenever it changes.
    var onChange: (([TypingTracker.Typist]) -> Void)?
    private(set) var room: String?
    private(set) var typists: [TypingTracker.Typist] = []

    private var tracker = TypingTracker()
    private let isEnabled: () -> Bool
    private let send: @Sendable (_ toSession: String, _ isTyping: Bool) async -> Void
    private var beatTask: Task<Void, Never>?
    private var typedSinceBeat = false
    private var expiryTask: Task<Void, Never>?

    init(ownUserID: String, isEnabled: @escaping () -> Bool, send: @escaping @Sendable (String, Bool) async -> Void) {
        tracker.ownUserID = ownUserID
        self.isEnabled = isEnabled
        self.send = send
    }

    // MARK: - From the signaling server

    /// Connected with this signaling session, or not connected (nil): a new session is in no
    /// conversation yet.
    func connected(sessionID: String?) {
        guard tracker.ownSessionID != sessionID else { return }
        tracker.ownSessionID = sessionID
        if sessionID == nil { roomChanged("") }
    }

    func roomChanged(_ roomID: String) {
        let room = roomID.isEmpty ? nil : roomID
        // The same conversation again — after a rejoin the server lists everyone anew.
        if room != self.room { cancelBeat() }
        self.room = room
        tracker.reset()
        publish()
    }

    func joined(_ sessions: [RoomSession]) {
        let arriving = sessions.filter { tracker.sessions[$0.signalingID] == nil && $0.signalingID != tracker.ownSessionID }
        tracker.joined(sessions)
        // Someone who arrives while the user is typing hears about it, as in Talk.
        if beatTask != nil { broadcast(true, to: arriving.map(\.signalingID)) }
        publish()
    }

    func left(_ sessionIDs: [String]) {
        tracker.left(sessionIDs)
        publish()
    }

    func received(fromSession id: String, isTyping: Bool) {
        tracker.received(fromSession: id, isTyping: isTyping, at: Date())
        publish()
    }

    /// A session's name, as the signaling server gave it when they joined the conversation.
    func displayName(forSession id: String) -> String? {
        tracker.sessions[id]?.displayName
    }

    // MARK: - From the composer

    /// The text in the composer of `token` changed by the user's hand.
    func draftEdited(token: String, isEmpty: Bool) {
        guard token == room, isEnabled() else { return }
        guard !isEmpty else { stopTyping(); return }
        guard beatTask == nil else {
            typedSinceBeat = true
            return
        }
        broadcast(true, to: tracker.recipients)
        beatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.beat)
                guard let self, !Task.isCancelled else { return }
                if self.typedSinceBeat {
                    self.typedSinceBeat = false
                    self.broadcast(true, to: self.tracker.recipients)
                } else {
                    self.stopTyping()
                    return
                }
            }
        }
    }

    /// Sent, cleared, or left: tell everyone the typing is over, if they were told it began.
    func stopTyping() {
        guard beatTask != nil else { return }
        cancelBeat()
        broadcast(false, to: tracker.recipients)
    }

    func tearDown() {
        cancelBeat()
        expiryTask?.cancel()
        onChange = nil
    }

    // MARK: -

    private func cancelBeat() {
        beatTask?.cancel()
        beatTask = nil
        typedSinceBeat = false
    }

    private func broadcast(_ isTyping: Bool, to sessions: [String]) {
        guard !sessions.isEmpty else { return }
        let send = send
        Task { for session in sessions { await send(session, isTyping) } }
    }

    private func publish() {
        let now = Date()
        let current = isEnabled() ? tracker.typists(at: now) : []
        if current != typists {
            typists = current
            onChange?(current)
        }
        expiryTask?.cancel()
        guard let next = tracker.nextExpiry(after: now) else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }
}
