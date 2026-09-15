import Foundation

/// A poll in a conversation.
///
/// Three of these fields are absent more often than they are present: Nextcloud withholds
/// the results until the reader has earned them — see ``Poll/results``.
struct Poll: Sendable, Equatable, Identifiable {
    enum Status: Int, Sendable {
        case open = 0
        case closed = 1
        /// Not yet posted. This project doesn't create drafts, but can be shown one.
        case draft = 2
    }

    enum ResultMode: Int, Sendable {
        /// Counts, and who voted for what, visible from the start.
        case visible = 0
        /// Counts only, and only once the poll is closed.
        case hiddenUntilClosed = 1
    }

    let id: Int
    var question: String
    /// An option's id is its index here.
    var options: [String]
    var actor: MessageActor
    var status: Status
    var resultMode: ResultMode
    /// How many options one participant may choose. **Zero means unlimited.**
    var maxVotes: Int
    /// Option ids this participant chose. Empty means they haven't voted.
    var votedSelf: [Int]

    /// Counts by option id, once the server is willing to say — see ``results``. An option
    /// nobody chose is missing rather than zero, so read it through ``votes(for:)``.
    var voteCounts: [Int: Int]?
    var voterCount: Int?
    /// Who voted for what. Public closed polls only.
    var details: [PollVote]?

    /// Whether the server has told us the results yet.
    ///
    /// It withholds them until the reader has voted on a visible-result poll, or the poll
    /// has closed (the author and moderators see them sooner). So "no results" is the
    /// normal state of the first poll anyone is shown, not an error.
    var hasResults: Bool { voteCounts != nil }

    /// Votes for one option, counting an absent entry as the nought it means.
    func votes(for optionID: Int) -> Int { voteCounts?[optionID] ?? 0 }

    var hasVoted: Bool { !votedSelf.isEmpty }
    var allowsMultipleAnswers: Bool { maxVotes == 0 || maxVotes > 1 }
}

/// One person's choice, for the breakdown under a closed public poll.
struct PollVote: Sendable, Equatable, Identifiable {
    var id: String { "\(actor.kind.rawValue):\(actor.id):\(optionID)" }
    var actor: MessageActor
    var optionID: Int
}

/// Talk's polls. Requires the `talk-polls` capability.
///
/// See `docs/NEXTCLOUD_API.md` § 14 — in particular that `votes` comes back as a map keyed
/// `"option-<id>"` rather than an array beside `options`, which is what the prose
/// documentation reads as.
actor PollService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func create(
        token: String,
        question: String,
        options: [String],
        resultMode: Poll.ResultMode,
        maxVotes: Int
    ) async throws(TalkError) -> Poll {
        var form: [String: String] = [
            "question": question,
            "resultMode": String(resultMode.rawValue),
            "maxVotes": String(maxVotes)
        ]
        // Indexed keys rather than a repeated `options[]`: the form is a dictionary, and PHP
        // reads `options[0]`, `options[1]`… as the same array either way.
        for (index, option) in options.enumerated() {
            form["options[\(index)]"] = option
        }

        let response = try await client.send(OCSRequest.post(Endpoint.poll(token), form: form), as: PollDTO.self)
        return try poll(from: response.value)
    }

    func poll(token: String, pollID: Int) async throws(TalkError) -> Poll {
        let response = try await client.send(OCSRequest.get(Endpoint.poll(token, pollID)), as: PollDTO.self)
        return try poll(from: response.value)
    }

    /// Casts, changes or retracts a vote. Voting again replaces what was there before, and
    /// an empty `optionIDs` takes the vote back.
    func vote(token: String, pollID: Int, optionIDs: [Int]) async throws(TalkError) -> Poll {
        var form: [String: String] = [:]
        for (index, optionID) in optionIDs.enumerated() {
            form["optionIds[\(index)]"] = String(optionID)
        }

        let response = try await client.send(
            OCSRequest.post(Endpoint.poll(token, pollID), form: form),
            as: PollDTO.self
        )
        return try poll(from: response.value)
    }

    /// Ends the poll, which is what publishes the results of a hidden one. The author and
    /// moderators may; everyone else gets a 403.
    func close(token: String, pollID: Int) async throws(TalkError) -> Poll {
        let response = try await client.send(OCSRequest.delete(Endpoint.poll(token, pollID)), as: PollDTO.self)
        return try poll(from: response.value)
    }

    private func poll(from dto: PollDTO?) throws(TalkError) -> Poll {
        guard let dto else { throw .unexpectedResponse("The server sent a poll with nothing in it") }
        return dto.model
    }
}

// MARK: - Wire format

private struct PollDTO: Decodable, Sendable {
    let id: Int
    let question: String
    let options: [String]
    let actorType: String
    let actorId: String
    let actorDisplayName: String
    let status: Int
    let resultMode: Int
    let maxVotes: Int
    let votedSelf: [Int]?
    let votes: [String: Int]?
    let numVoters: Int?
    let details: [PollVoteDTO]?

    var model: Poll {
        Poll(
            id: id,
            question: question,
            options: options,
            actor: MessageActor(type: actorType, id: actorId, displayName: actorDisplayName),
            // An unknown status is treated as closed rather than open: offering a vote that
            // the server will refuse is worse than not offering one.
            status: Poll.Status(rawValue: status) ?? .closed,
            resultMode: Poll.ResultMode(rawValue: resultMode) ?? .hiddenUntilClosed,
            maxVotes: maxVotes,
            votedSelf: votedSelf ?? [],
            voteCounts: Self.counts(from: votes),
            voterCount: numVoters,
            details: details?.map(\.model)
        )
    }

    /// `{"option-0": 3}` → `[0: 3]`. Anything not shaped like that is dropped rather than
    /// guessed at.
    private static func counts(from votes: [String: Int]?) -> [Int: Int]? {
        guard let votes else { return nil }
        var counts: [Int: Int] = [:]
        for (key, count) in votes {
            guard let id = Int(key.dropFirst("option-".count)), key.hasPrefix("option-") else { continue }
            counts[id] = count
        }
        return counts
    }
}

private struct PollVoteDTO: Decodable, Sendable {
    let actorType: String
    let actorId: String
    let actorDisplayName: String
    let optionId: Int

    var model: PollVote {
        PollVote(
            actor: MessageActor(type: actorType, id: actorId, displayName: actorDisplayName),
            optionID: optionId
        )
    }
}
