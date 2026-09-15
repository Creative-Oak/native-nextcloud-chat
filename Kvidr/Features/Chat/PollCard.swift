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

    /// Re-reads a poll. Someone else voting says nothing on the wire — this project has no
    /// signaling — so this is what the card falls back on rather than a timer per poll.
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

/// A poll in the transcript: the question, its options, and what everyone chose.
struct PollCard: View {
    /// From the message's rich object — all it carries besides the question.
    let pollID: Int
    let question: String

    @Environment(\.pollStore) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let poll = store?.poll(pollID) {
                ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                    PollOptionRow(poll: poll, optionID: index, label: option) {
                        Task { await store?.toggle(option: index, on: pollID) }
                    }
                }
                footer(poll)
            } else if let message = store?.failures[pollID] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .task { await store?.load(pollID) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundStyle(.secondary)
            // The question comes with the message, so it is on screen before the fetch
            // lands — the card fills in around it rather than appearing from nothing.
            Text(question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func footer(_ poll: Poll) -> some View {
        HStack(spacing: 8) {
            Text(summary(poll))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if store?.canClose(poll) == true {
                Button("End Poll") { Task { await store?.close(pollID) } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private func summary(_ poll: Poll) -> String {
        if poll.status == .closed {
            let voters = poll.voterCount ?? 0
            return voters == 1 ? "Closed · 1 vote" : "Closed · \(voters) votes"
        }
        if !poll.hasResults {
            // The honest reading of a withheld result, rather than a row of zeroes that
            // looks like nobody has voted.
            return poll.resultMode == .hiddenUntilClosed
                ? "Results when the poll closes"
                : "Vote to see the results"
        }
        let voters = poll.voterCount ?? 0
        return voters == 1 ? "1 vote so far" : "\(voters) votes so far"
    }
}

/// One option: a checkable row that doubles as its own result bar.
private struct PollOptionRow: View {
    let poll: Poll
    let optionID: Int
    let label: String
    var onTap: () -> Void

    private var isChosen: Bool { poll.votedSelf.contains(optionID) }
    private var isVotable: Bool { poll.status == .open }

    private var share: Double {
        guard poll.hasResults, let total = poll.voterCount, total > 0 else { return 0 }
        // Clamped: nothing should exceed the voter count, but a bar wider than its row is a
        // worse way to find out that something did.
        return min(1, Double(poll.votes(for: optionID)) / Double(total))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)

                Text(label)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if poll.hasResults {
                    Text("\(poll.votes(for: optionID))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(alignment: .leading) {
                // The bar is the row's own background rather than a separate track: a poll
                // with results should read as a chart without turning into one.
                if poll.hasResults {
                    GeometryReader { proxy in
                        Color.accentColor.opacity(0.14)
                            .frame(width: proxy.size.width * share)
                    }
                }
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(.rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isVotable)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        // A closed poll is a record, not a control, so it loses the affordance rather than
        // showing an empty box nobody can tick.
        if !isVotable { return isChosen ? "checkmark.circle.fill" : "circle.dotted" }
        if poll.allowsMultipleAnswers { return isChosen ? "checkmark.square.fill" : "square" }
        return isChosen ? "largecircle.fill.circle" : "circle"
    }

    private var accessibilityLabel: String {
        guard poll.hasResults else { return label }
        let votes = poll.votes(for: optionID)
        return votes == 1 ? "\(label), 1 vote" : "\(label), \(votes) votes"
    }
}
