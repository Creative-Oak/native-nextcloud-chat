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

    @Test("A poll you have just made decodes, empty vote array and all")
    func freshlyCreatedPollDecodes() async throws {
        // What the server actually sends back from `create`: `renderPoll` assigns an empty
        // PHP array to `votes` while it is withholding the results, and `json_encode` writes
        // that as `[]` rather than `{}`. Typed as a dictionary, this fails to decode — and
        // it is the very first poll anyone sees.
        let extra = #","votes":[],"numVoters":0,"votedSelf":[]"#
        let transport = StubTransport(json: ocsEnvelope(pollJSON(extra: extra)))
        let service = PollService(client: try client(transport))

        let poll = try await service.poll(token: "tok", pollID: 7)

        #expect(poll.id == 7)
        #expect(poll.options.count == 3)
        #expect(poll.votes(for: 0) == 0)
    }

    @Test("An open poll you haven't voted in withholds its results, and says so")
    func openPollWithheldResults() async throws {
        let extra = #","votes":[],"numVoters":0,"votedSelf":[]"#
        let transport = StubTransport(json: ocsEnvelope(pollJSON(extra: extra)))
        let service = PollService(client: try client(transport))

        let poll = try await service.poll(token: "tok", pollID: 7)

        // The empty map means "nobody voted" and "you may not see" at the same time, so this
        // is decided the way the server decides it rather than by the field being there.
        #expect(poll.hasResults == false)
        #expect(poll.hasVoted == false)
        #expect(poll.votes(for: 0) == 0)
    }

    @Test("Voting on a visible-result poll is what opens the results")
    func votingRevealsResults() async throws {
        let extra = #","votes":{"option-0":1},"numVoters":1,"votedSelf":[0]"#
        let transport = StubTransport(json: ocsEnvelope(pollJSON(extra: extra)))
        let service = PollService(client: try client(transport))
        #expect(try await service.poll(token: "tok", pollID: 7).hasResults)
    }

    @Test("A hidden-result poll stays shut until it closes, even after you vote")
    func hiddenResultsStayHidden() async throws {
        let voted = #","votes":[],"numVoters":0,"votedSelf":[0]"#
        var transport = StubTransport(json: ocsEnvelope(pollJSON(resultMode: 1, extra: voted)))
        #expect(try await PollService(client: try client(transport)).poll(token: "tok", pollID: 7).hasResults == false)

        let closed = #","votes":{"option-0":2},"numVoters":2,"votedSelf":[0]"#
        transport = StubTransport(json: ocsEnvelope(pollJSON(status: 1, resultMode: 1, extra: closed)))
        #expect(try await PollService(client: try client(transport)).poll(token: "tok", pollID: 7).hasResults)
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
        #expect(poll.voteCounts == [0: 3, 1: 1])
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

    @Test("A refusal says which rule it broke, not just that there was one")
    func refusalsAreExplained() async throws {
        // Talk answers 400 with `ocs.data.error`, a single word. That body cannot decode as
        // a poll, which is exactly where the reason used to get thrown away.
        let body = #"{"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"room"}}}"#
        let transport = StubTransport(json: body, status: 400)
        let service = PollService(client: try client(transport))

        await #expect(throws: TalkError.self) {
            _ = try await service.create(
                token: "tok", question: "Lunch?", options: ["Pizza", "Sushi"],
                resultMode: .visible, maxVotes: 1
            )
        }

        do {
            _ = try await service.create(
                token: "tok", question: "Lunch?", options: ["Pizza", "Sushi"],
                resultMode: .visible, maxVotes: 1
            )
            Issue.record("expected a refusal")
        } catch {
            // Not the word "room", which is what the server actually said.
            #expect(error.userMessage.contains("group and public conversations"))
        }
    }

    @Test("Polls belong to group and public conversations only", arguments: [
        (ConversationType.oneToOne, false), (.group, true), (.publicRoom, true)
    ])
    func whereAPollMayLive(_ input: (ConversationType, Bool)) {
        // `PollController::createPoll` refuses anything else outright, so the + menu asks
        // this before it offers the item rather than letting the server say no.
        #expect(input.0.allowsPolls == input.1)
    }

    @Test("A status the client doesn't know closes the poll rather than offering a vote")
    func unknownStatusIsClosed() async throws {
        let transport = StubTransport(json: ocsEnvelope(pollJSON(status: 99)))
        let service = PollService(client: try client(transport))
        let poll = try await service.poll(token: "tok", pollID: 7)
        #expect(poll.status == .closed)
    }
}

@Suite("Messages that draw their own shape")
struct StandaloneAttachmentTests {
    private func poll(_ id: String = "7") -> RichObject {
        RichObject(type: .talkPoll, id: id, name: "Lunch?")
    }

    private func image(_ id: String = "3", preview: Bool = true) -> RichObject {
        RichObject(
            type: .file, id: id, name: "cat.jpeg",
            attributes: ["mimetype": "image/jpeg", "preview-available": preview ? "yes" : "no"]
        )
    }

    @Test("A poll on its own gets no bubble")
    func soloPoll() {
        let content = MessageContent(blocks: [.attachment(poll())], mentionsCurrentUser: false)
        #expect(content.standalone?.object.id == "7")
        #expect(content.standalone?.caption.isEmpty == true)
    }

    @Test("A captioned picture keeps its words, to go in a bubble of their own")
    func captionedImage() {
        // What Talk sends for a photo with a caption: the words, then the file.
        let content = MessageContent(
            blocks: [.paragraph([.text("Hep")]), .attachment(image())],
            mentionsCurrentUser: false
        )
        let standalone = content.standalone
        #expect(standalone?.object.id == "3")
        #expect(standalone?.caption.count == 1)
        // The picture is drawn first and the caption under it, so the words come back
        // separately rather than staying in the order the server sent them.
        #expect(standalone?.caption.first?.plainText == "Hep")
    }

    @Test("A picture the server can't preview stays a row in a bubble")
    func unpreviewableImage() {
        let content = MessageContent(blocks: [.attachment(image(preview: false))], mentionsCurrentUser: false)
        // Nothing to draw means nothing to draw bare: it falls back to the file row, which
        // needs the bubble to sit in.
        #expect(content.standalone == nil)
    }

    @Test("A plain file is a row, not a shape")
    func plainFile() {
        let file = RichObject(type: .file, id: "9", name: "report.pdf", attributes: ["mimetype": "application/pdf"])
        let content = MessageContent(blocks: [.attachment(file)], mentionsCurrentUser: false)
        #expect(content.standalone == nil)
    }

    @Test("Two pictures have no obvious arrangement, so the bubble keeps them")
    func twoImages() {
        let content = MessageContent(
            blocks: [.attachment(image("1")), .attachment(image("2"))],
            mentionsCurrentUser: false
        )
        #expect(content.standalone == nil)
    }

    @Test("An ordinary message is untouched")
    func plainText() {
        let content = MessageContent(blocks: [.paragraph([.text("hello")])], mentionsCurrentUser: false)
        #expect(content.standalone == nil)
    }
}
