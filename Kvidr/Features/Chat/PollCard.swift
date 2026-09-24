import SwiftUI

/// Holds the polls on screen, and does the four things you can do to one.
///
/// A message carries only a poll's id and its question, so every card has to fetch the rest
/// of itself. This keeps one copy per id so that two cards for the same poll — a reply quote
/// and the message it quotes, say — do not fetch twice or disagree.
@MainActor
@Observable
final class PollStore {
    private(set) var polls: [Int: Poll] = [:]
    private(set) var failures: [Int: String] = [:]
    @ObservationIgnored private var inFlight: Set<Int> = []

    private let session: Session
    private let token: String

    init(session: Session, token: String) {
        self.session = session
        self.token = token
    }

    /// The current user, for deciding who may close a poll.
    var isModerator: Bool = false

    func poll(_ id: Int) -> Poll? { polls[id] }

    func load(_ id: Int) async {
        guard polls[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        await fetch(id)
    }

    /// Casts, changes or retracts. An option already chosen is unchosen, which is how a
    /// single-answer poll lets you change your mind and a multiple-answer one lets you drop
    /// one of several.
    func toggle(option: Int, on id: Int) async {
        guard let poll = polls[id], poll.status == .open else { return }

        var chosen = Set(poll.votedSelf)
        if chosen.contains(option) {
            chosen.remove(option)
        } else {
            if !poll.allowsMultipleAnswers { chosen.removeAll() }
            chosen.insert(option)
        }

        do {
            polls[id] = try await session.polls.vote(token: token, pollID: id, optionIDs: Array(chosen).sorted())
            failures[id] = nil
        } catch {
            failures[id] = error.userMessage
        }
    }

    func close(_ id: Int) async {
        do {
            polls[id] = try await session.polls.close(token: token, pollID: id)
            failures[id] = nil
        } catch {
            failures[id] = error.userMessage
        }
    }

    /// Re-reads a poll — when Talk's hidden "voted" or "closed" line for it comes in the chat,
    /// which is how others' votes show up live.
    func refresh(_ id: Int) async {
        await fetch(id)
    }

    private func fetch(_ id: Int) async {
        do {
            polls[id] = try await session.polls.poll(token: token, pollID: id)
            failures[id] = nil
        } catch {
            failures[id] = error.userMessage
        }
    }

    /// Whether this user may end the poll: its author, or a moderator.
    func canClose(_ poll: Poll) -> Bool {
        poll.status == .open && (isModerator || session.account.isMe(poll.actor))
    }
}

private struct PollStoreKey: EnvironmentKey {
    static let defaultValue: PollStore? = nil
}

extension EnvironmentValues {
    var pollStore: PollStore? {
        get { self[PollStoreKey.self] }
        set { self[PollStoreKey.self] = newValue }
    }
}

/// A poll in the transcript, drawn as Messages draws one: a stack of capsules whose widths
/// are the result, rather than a card with a chart in it.
///
/// It has no container of its own — `MessageRow` skips the bubble for a message that is
/// nothing but a poll, so these sit on the transcript the way Messages' do.
struct PollCard: View {
    /// From the message's rich object — all it carries besides the question.
    let pollID: Int
    let question: String
    var isFromMe = false

    @Environment(\.pollStore) private var store
    /// Measured once here rather than per row: every capsule's width is a fraction of it.
    @State private var available: CGFloat = 260

    private var alignment: HorizontalAlignment { isFromMe ? .trailing : .leading }
    private var frameAlignment: Alignment { isFromMe ? .trailing : .leading }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            if let poll = store?.poll(pollID) {
                ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                    PollOptionCapsule(
                        poll: poll,
                        optionID: index,
                        label: option,
                        width: width(for: poll, option: index)
                    ) {
                        Task { await store?.toggle(option: index, on: pollID) }
                    }
                }
                footer(poll)
            } else if let message = store?.failures[pollID] {
                Text(message).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: 320, alignment: frameAlignment)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .task { await store?.load(pollID) }
    }

    /// Capsules start at a little under two thirds and grow to the full width with their
    /// share of the vote. That baseline is what keeps an unvoted poll from reading as a
    /// column of empty bars, and what makes a leading option obvious at a glance.
    private func width(for poll: Poll, option: Int) -> CGFloat {
        let base = 0.62
        guard poll.hasResults, let voters = poll.voterCount, voters > 0 else { return available * base }
        let share = min(1, Double(poll.votes(for: option)) / Double(voters))
        return available * (base + (1 - base) * share)
    }

    @ViewBuilder
    private func footer(_ poll: Poll) -> some View {
        HStack(spacing: 8) {
            if store?.canClose(poll) == true {
                Button("End Poll") { Task { await store?.close(pollID) } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text(summary(poll))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func summary(_ poll: Poll) -> String {
        if poll.status == .closed {
            let voters = poll.voterCount ?? 0
            return String(localized: "Ended · \(voters) votes", comment: "Under a closed poll: how many voted")
        }
        if !poll.hasResults {
            // The honest reading of a withheld result, rather than a row of noughts that
            // looks like nobody has voted.
            return poll.resultMode == .hiddenUntilClosed
                ? String(localized: "Results when it ends", comment: "Under a poll whose results are hidden until it closes")
                : String(localized: "Vote to see results", comment: "Under a poll")
        }
        let voters = poll.voterCount ?? 0
        return String(localized: "\(voters) votes", comment: "Under a poll: how many voted")
    }
}

/// One option: a capsule that is its own result bar.
private struct PollOptionCapsule: View {
    let poll: Poll
    let optionID: Int
    let label: String
    let width: CGFloat
    var onTap: () -> Void

    private var isChosen: Bool { poll.votedSelf.contains(optionID) }
    private var isVotable: Bool { poll.status == .open }
    /// Filled when it has something to show for itself: your own vote, or votes you can see.
    private var isFilled: Bool { isChosen || (poll.hasResults && poll.votes(for: optionID) > 0) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if poll.hasResults {
                    Text("\(poll.votes(for: optionID))")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .opacity(0.75)
                }

                mark
            }
            .foregroundStyle(isFilled ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: width, alignment: .leading)
            .background(isFilled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.15)))
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isVotable)
        .animation(.smooth(duration: 0.25), value: width)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The ring at the trailing edge, ticked when it is one of yours. Messages puts the
    /// voters' faces here; Talk only says who voted once a public poll has closed, so a
    /// ring that is honest about your own vote beats a row of faces that is often missing.
    @ViewBuilder
    private var mark: some View {
        if isChosen {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.accentColor, .white)
        } else {
            Circle()
                .strokeBorder(isFilled ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(Color.accentColor.opacity(0.55)), lineWidth: 1.5)
                .frame(width: 19, height: 19)
        }
    }

    private var accessibilityLabel: String {
        guard poll.hasResults else { return label }
        let votes = poll.votes(for: optionID)
        return String(localized: "\(label), \(votes) votes", comment: "VoiceOver: a poll option, and how many voted for it")
    }
}
