import Foundation
import Testing
@testable import TalkCore

private func client(_ transport: StubTransport) throws -> OCSClient {
    OCSClient(
        server: try ServerAddress.parse("https://cloud.example.com"),
        credentials: Credentials(loginName: "alice", appPassword: "pw"),
        transport: transport
    )
}

private func pollJSON(
    status: Int = 0,
    resultMode: Int = 0,
    maxVotes: Int = 1,
    extra: String = ""
) -> String {
    """
    {"id":7,"question":"Lunch?","options":["Pizza","Sushi","Salad"],
     "actorType":"users","actorId":"bob","actorDisplayName":"Bob",
     "status":\(status),"resultMode":\(resultMode),"maxVotes":\(maxVotes)\(extra)}
    """
}

private func form(_ request: HTTPRequest) -> [String: String] {
    let body = String(decoding: request.body ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        fields[key] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }
    return fields
}

@Suite("Polls")
struct PollServiceTests {
    @Test("Creating a poll sends the options as an indexed array")
    func create() async throws {
        let transport = StubTransport(json: ocsEnvelope(pollJSON()))
        let service = PollService(client: try client(transport))

        let poll = try await service.create(
            token: "tok",
            question: "Lunch?",
            options: ["Pizza", "Sushi", "Salad"],
            resultMode: .visible,
            maxVotes: 1
        )

        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/poll/tok")

        let fields = form(request)
        #expect(fields["question"] == "Lunch?")
        #expect(fields["resultMode"] == "0")
        #expect(fields["maxVotes"] == "1")
        // The form is a dictionary, so the array is indexed rather than a repeated key.
        #expect(fields["options[0]"] == "Pizza")
        #expect(fields["options[1]"] == "Sushi")
        #expect(fields["options[2]"] == "Salad")

        #expect(poll.id == 7)
        #expect(poll.options.count == 3)
        #expect(poll.status == .open)
    }

    @Test("An open poll you haven't voted in has no results, and that is not an error")
    func openPollWithheldResults() async throws {
        // No `votes`, no `numVoters`, no `votedSelf` — the shape of every poll before you
        // have voted in it. A client that requires those fields cannot decode this.
        let transport = StubTransport(json: ocsEnvelope(pollJSON()))
        let service = PollService(client: try client(transport))

        let poll = try await service.poll(token: "tok", pollID: 7)

        #expect(poll.hasResults == false)
        #expect(poll.hasVoted == false)
        #expect(poll.votedSelf.isEmpty)
        #expect(poll.voterCount == nil)
        // Reading a count anyway answers nought rather than trapping.
        #expect(poll.votes(for: 0) == 0)
    }

    @Test("Vote counts arrive as a map keyed by option name, not an array")
    func voteCountsAreAMap() async throws {
        // The trap: `votes` is `{"option-<id>": count}`, and an option nobody chose is
        // missing rather than zero. Salad, option 2, got nothing.
        let extra = #","votes":{"option-0":3,"option-1":1},"numVoters":4,"votedSelf":[0]"#
        let transport = StubTransport(json: ocsEnvelope(pollJSON(extra: extra)))
        let service = PollService(client: try client(transport))

        let poll = try await service.poll(token: "tok", pollID: 7)

        #expect(poll.votes(for: 0) == 3)
        #expect(poll.votes(for: 1) == 1)
        #expect(poll.votes(for: 2) == 0)   // absent, not zero, on the wire
        #expect(poll.voterCount == 4)
        #expect(poll.votedSelf == [0])
        #expect(poll.hasVoted)
        #expect(poll.hasResults)
    }

    @Test("A vote sends the chosen option ids; an empty vote retracts")
    func voting() async throws {
        let transport = StubTransport(json: ocsEnvelope(pollJSON(extra: #","votedSelf":[1,2]"#)))
        let service = PollService(client: try client(transport))

        _ = try await service.vote(token: "tok", pollID: 7, optionIDs: [1, 2])
        var fields = form(try #require(transport.lastRequest))
        #expect(fields["optionIds[0]"] == "1")
        #expect(fields["optionIds[1]"] == "2")
        #expect(try #require(transport.lastRequest).url.path == "/ocs/v2.php/apps/spreed/api/v1/poll/tok/7")

        _ = try await service.vote(token: "tok", pollID: 7, optionIDs: [])
        fields = form(try #require(transport.lastRequest))
        // Nothing to send is how a vote is taken back; the server's default is an empty array.
        #expect(fields.keys.contains { $0.hasPrefix("optionIds") } == false)
    }

    @Test("Closing a poll is a DELETE, and publishes who voted for what")
    func close() async throws {
        let extra = """
        ,"votes":{"option-0":2},"numVoters":2,"votedSelf":[0],
        "details":[{"actorType":"users","actorId":"bob","actorDisplayName":"Bob","optionId":0},
                   {"actorType":"users","actorId":"cara","actorDisplayName":"Cara","optionId":0}]
        """
        let transport = StubTransport(json: ocsEnvelope(pollJSON(status: 1, extra: extra)))
        let service = PollService(client: try client(transport))

        let poll = try await service.close(token: "tok", pollID: 7)

        #expect(try #require(transport.lastRequest).method == .delete)
        #expect(poll.status == .closed)
        #expect(poll.details?.count == 2)
        #expect(poll.details?.first?.actor.id == "bob")
        #expect(poll.details?.first?.optionID == 0)
    }

    @Test("Unlimited and multiple choice both read as more than one answer")
    func multipleAnswers() async throws {
        for (maxVotes, expected) in [(0, true), (1, false), (2, true)] {
            let transport = StubTransport(json: ocsEnvelope(pollJSON(maxVotes: maxVotes)))
            let service = PollService(client: try client(transport))
            let poll = try await service.poll(token: "tok", pollID: 7)
            // Zero means unlimited, not "no votes allowed" — the one place that constant
            // reads backwards if you skim it.
            #expect(poll.allowsMultipleAnswers == expected)
        }
    }

    @Test("A status the client doesn't know closes the poll rather than offering a vote")
    func unknownStatusIsClosed() async throws {
        let transport = StubTransport(json: ocsEnvelope(pollJSON(status: 99)))
        let service = PollService(client: try client(transport))
        let poll = try await service.poll(token: "tok", pollID: 7)
        #expect(poll.status == .closed)
    }
}
