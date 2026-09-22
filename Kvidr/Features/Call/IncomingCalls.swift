import AppKit
import AVFoundation
import Foundation

/// Someone calling: a call newly under way in a conversation that notifies of calls, which the
/// server says is still ringing for this user. It rings — a banner in the window, a ringtone,
/// the Dock, and a notification when kvidr isn't in front — until it's answered or declined
/// here, or the server says it's over: answered elsewhere, given up on, or missed.
@MainActor
@Observable
final class IncomingCalls {
    struct Ringing: Equatable {
        let token: String
        var conversation: Conversation
        let since: Date
    }

    private(set) var ringing: Ringing?
    /// Answered here, and not yet joined; or a one-to-one's declined call, not yet seen to end.
    /// Either way the conversation's own "call in progress" bar would flash up for a moment.
    private(set) var settling: Set<String> = []

    /// Whether the conversation's "call in progress" bar should stay out of the way.
    func coversCallBar(for token: String) -> Bool {
        ringing?.token == token || settling.contains(token)
    }

    /// Set by the app.
    @ObservationIgnored var onAnswer: (String) -> Void = { _ in }
    /// A one-to-one's call declined: with only the caller left in it, it ends.
    @ObservationIgnored var onDeclineOneToOne: (String) -> Void = { _ in }
    @ObservationIgnored var isInCall: (String) -> Bool = { _ in false }
    @ObservationIgnored var isDoNotDisturb: () -> Bool = { false }


    @ObservationIgnored private let session: Session
    @ObservationIgnored private let notifications: NotificationController
    @ObservationIgnored private let preferences: Preferences
    /// Conversations known to have a call, so only a call that has just started rings.
    @ObservationIgnored private var withCall: Set<String>?
    /// Calls declined here: they don't ring again until they have ended.
    @ObservationIgnored private var declined: Set<String> = []
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?

    static let giveUpAfter: TimeInterval = 60
    static let checkEvery: Duration = .seconds(3)

    init(session: Session, notifications: NotificationController, preferences: Preferences) {
        self.session = session
        self.notifications = notifications
        self.preferences = preferences
    }

    // MARK: - Noticing

    /// The conversation list changed: a call that has just appeared may be for this user.
    func conversationsChanged(_ conversations: [Conversation]) {
        let now = Set(conversations.filter(\.hasCall).map(\.token))
        let previous = withCall
        withCall = now
        declined.formIntersection(now)
        settling.formIntersection(now)
        if let ringing, !now.contains(ringing.token) { stop() }
        guard let previous else {
            // The first look, at launch: only a call that has only just started counts.
            for conversation in conversations where conversation.hasCall {
                if let start = conversation.callStartTime, Date().timeIntervalSince(start) < 45 { consider(conversation) }
            }
            return
        }
        for token in now.subtracting(previous) {
            if let conversation = conversations.first(where: { $0.token == token }) { consider(conversation) }
        }
    }

    /// The server's own call notification came in — another way of hearing the same.
    func serverAnnounced(_ conversation: Conversation) {
        consider(conversation)
    }

    private func consider(_ conversation: Conversation) {
        guard ringing == nil,
              session.capabilitySnapshot.config.callEnabled != false,
              conversation.notificationCalls != 0,
              !declined.contains(conversation.token),
              !isInCall(conversation.token),
              !(isDoNotDisturb() && !conversation.isImportant)
        else { return }
        let calls = session.calls
        // Kept out of the way while the server is asked, so the conversation's "call in
        // progress" bar doesn't show for that moment before the ringing does.
        settling.insert(conversation.token)
        Task { [weak self] in
            // The server knows whether it rings for this user: not if they started it
            // themselves, or it was answered on another device already.
            let state = try? await calls.notificationState(token: conversation.token)
            guard let self else { return }
            guard state == .ringing, self.ringing == nil, !self.isInCall(conversation.token) else {
                // Not for this user after all: a call someone else is having, bar and all.
                if self.ringing?.token != conversation.token, !self.isInCall(conversation.token) {
                    self.settling.remove(conversation.token)
                }
                return
            }
            self.settling.remove(conversation.token)
            self.start(conversation)
        }
    }

    // MARK: - Ringing

    private func start(_ conversation: Conversation) {
        let ring = Ringing(token: conversation.token, conversation: conversation, since: Date())
        ringing = ring
        playRingtone()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
            notifications.announceIncomingCall(conversation)
        }
        let calls = session.calls
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkEvery)
                guard let self, self.ringing?.token == ring.token else { return }
                if Date().timeIntervalSince(ring.since) > Self.giveUpAfter {
                    self.stop()
                    return
                }
                let state = try? await calls.notificationState(token: ring.token)
                if let state, state != .ringing {
                    self.stop()
                    return
                }
            }
        }
    }

    func answer() {
        guard let ringing else { return }
        settling.insert(ringing.token)
        stop()
        onAnswer(ringing.token)
    }

    /// Stops the ringing. In a one-to-one the call ends too — the caller would otherwise ring
    /// on alone — as a phone's does; in a group it goes on for the others.
    func decline() {
        guard let ringing else { return }
        declined.insert(ringing.token)
        if ringing.conversation.isOneToOne { settling.insert(ringing.token) }
        stop()
        if ringing.conversation.isOneToOne { onDeclineOneToOne(ringing.token) }
    }

    /// Answered from the notification, or joined some other way.
    func answered(_ token: String) {
        if ringing?.token == token {
            settling.insert(token)
            stop()
        }
    }

    /// The call is under way here, and its stage says so.
    func joined(_ token: String) {
        settling.remove(token)
    }

    /// kvidr went behind while it rings: the notification, which the banner in the window can't
    /// be seen as from there.
    func applicationActiveChanged(_ isActive: Bool) {
        guard let ringing, !isActive else { return }
        notifications.announceIncomingCall(ringing.conversation)
    }

    func stop() {
        if let token = ringing?.token { notifications.withdrawIncomingCall(token: token) }
        ringing = nil
        watch?.cancel()
        watch = nil
        player?.stop()
        player = nil
    }

    // MARK: - The ringtone

    /// The iPhone's own ringtone where the Mac has it; a system sound otherwise.
    private func playRingtone() {
        guard preferences.playsNotificationSound else { return }
        let candidates = [
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Opening.m4r"),
            URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff"),
        ]
        for url in candidates {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.numberOfLoops = -1
            player.play()
            self.player = player
            return
        }
    }
}
