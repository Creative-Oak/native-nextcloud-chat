import Foundation
import Testing
@testable import TalkCore

private func suggestion(_ mentionID: String, label: String = "Someone", source: MentionSuggestion.Source = .users) -> MentionSuggestion {
    MentionSuggestion(id: mentionID, label: label, mentionID: mentionID, source: source)
}

@Suite("Mention composing")
struct MentionComposerTests {
    // MARK: - Detecting what the user is typing

    @Test("An @ at the start of the message opens a query")
    func atStart() {
        let query = MentionComposer.activeQuery(in: "@ali", caret: 4)
        #expect(query == MentionComposer.Query(start: 0, end: 4, text: "ali"))
    }

    @Test("An @ after a space opens a query")
    func afterSpace() {
        let query = MentionComposer.activeQuery(in: "hey @bo", caret: 7)
        #expect(query == MentionComposer.Query(start: 4, end: 7, text: "bo"))
    }

    @Test("A bare @ with nothing typed yet still counts")
    func bareAt() {
        #expect(MentionComposer.activeQuery(in: "hey @", caret: 5)?.text == "")
    }

    @Test("An email address does not open the autocomplete")
    func emailAddress() {
        #expect(MentionComposer.activeQuery(in: "mail me at alice@example.com", caret: 28) == nil)
    }

    @Test("The query ends at whitespace, so finished mentions don't reopen it")
    func stopsAtWhitespace() {
        #expect(MentionComposer.activeQuery(in: "@alice hello", caret: 12) == nil)
        #expect(MentionComposer.activeQuery(in: "@alice\nhello", caret: 12) == nil)
    }

    @Test("Only the mention the caret is inside is offered")
    func caretPosition() {
        let text = "@alice and @bob"
        #expect(MentionComposer.activeQuery(in: text, caret: 6)?.text == "alice")
        #expect(MentionComposer.activeQuery(in: text, caret: 15)?.text == "bob")
        // Between them, in the plain words, there is no query.
        #expect(MentionComposer.activeQuery(in: text, caret: 9) == nil)
    }

    @Test("An out-of-range caret is handled rather than trapping")
    func outOfRangeCaret() {
        #expect(MentionComposer.activeQuery(in: "hi", caret: 99) == nil)
        #expect(MentionComposer.activeQuery(in: "hi", caret: -1) == nil)
        #expect(MentionComposer.activeQuery(in: "", caret: 0) == nil)
    }

    // MARK: - Writing the mention

    @Test("A simple id is written bare")
    func simpleToken() {
        #expect(MentionComposer.token(for: suggestion("alice")) == "@alice")
    }

    @Test("Ids with spaces or slashes are quoted, exactly as the API requires")
    func quotedToken() {
        #expect(MentionComposer.token(for: suggestion("space user")) == "@\"space user\"")
        #expect(MentionComposer.token(for: suggestion("guest/random-string")) == "@\"guest/random-string\"")
        #expect(MentionComposer.token(for: suggestion("federated_user/alice@other.example.com"))
                == "@\"federated_user/alice@other.example.com\"")
    }

    @Test("A quote inside an id can't break out of the quoting")
    func cannotEscapeQuoting() {
        let token = MentionComposer.token(forMentionID: "evil\" @all \"x")
        #expect(token.hasPrefix("@\""))
        #expect(token.hasSuffix("\""))
        #expect(token.filter { $0 == "\"" }.count == 2)
    }

    // MARK: - Applying it

    @Test("Picking a suggestion replaces the typed query and leaves a trailing space")
    func appliesSuggestion() {
        let query = try! #require(MentionComposer.activeQuery(in: "hey @ali", caret: 8))
        let result = MentionComposer.apply(suggestion("alice"), to: "hey @ali", replacing: query)
        #expect(result.text == "hey @alice ")
        #expect(result.caret == 11)
    }

    @Test("Inserting in the middle keeps the rest of the sentence")
    func appliesInMiddle() {
        let text = "hey @ali can you look?"
        let query = try! #require(MentionComposer.activeQuery(in: text, caret: 8))
        let result = MentionComposer.apply(suggestion("alice"), to: text, replacing: query)
        // No doubled space: there was already one after the query.
        #expect(result.text == "hey @alice can you look?")
        #expect(result.caret == 10)
    }

    @Test("Everyone is written as its own mention id")
    func everyone() {
        let all = MentionSuggestion(id: "all", label: "Everyone", mentionID: "all", source: .calls)
        #expect(all.isEveryone)
        #expect(MentionComposer.token(for: all) == "@all")
    }

    // MARK: - The endpoint

    @Test("Suggestions come from the documented endpoint and use mentionId when present")
    func suggestionsRequest() async throws {
        let body = ocsEnvelope("""
        [{"id":"alice","label":"Alice Andersen","source":"users","mentionId":"alice","status":"online"},
         {"id":"design","label":"Design team","source":"groups","mentionId":"group/design"},
         {"id":"frank","label":"Frank","source":"federated_users","mentionId":"federated_user/frank@other.example.com"},
         {"id":"all","label":"Everyone","source":"calls","details":"Notify everyone"},
         {"id":"legacy","label":"Old Server User","source":"users"}]
        """)
        let transport = StubTransport(json: body)
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let suggestions = try await ChatService(client: client).mentionSuggestions(token: "tok", search: "a")

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/mentions")
        #expect(request.url.query()?.contains("search=a") == true)

        #expect(suggestions.count == 5)
        #expect(suggestions[0].mentionID == "alice")
        #expect(suggestions[0].status?.isOnline == true)
        #expect(MentionComposer.token(for: suggestions[1]) == "@\"group/design\"")
        #expect(MentionComposer.token(for: suggestions[2]) == "@\"federated_user/frank@other.example.com\"")
        #expect(suggestions[3].isEveryone)
        #expect(suggestions[3].details == "Notify everyone")
        // A server without `mentionId` falls back to the plain id.
        #expect(suggestions[4].mentionID == "legacy")
    }

    @Test("An empty search never hits the network")
    func emptySearchIsLocal() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        let suggestions = try await ChatService(client: client).mentionSuggestions(token: "tok", search: "")
        #expect(suggestions.isEmpty)
        #expect(transport.requestCount == 0)
    }

    @Test("A mention written by the composer parses back as a mention")
    func roundTrip() {
        // What we write must be what the server echoes back as a rich object — this is the
        // seam where a wrong quoting rule would show up as literal text in the transcript.
        let written = MentionComposer.token(for: suggestion("alice"))
        #expect(written == "@alice")

        let parser = MessageContentParser(currentUserID: "alice")
        let rendered = parser.parse(
            text: "Hi {mention-user1}",
            parameters: ["mention-user1": RichObject(type: .user, id: "alice", name: "Alice Andersen")],
            isMarkdown: false
        )
        #expect(rendered.mentionsCurrentUser)
    }
}
