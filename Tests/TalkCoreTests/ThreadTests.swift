import Foundation
import Testing
@testable import TalkCore

@Suite("Threads")
struct ThreadTests {
    private func decode(_ json: String) throws -> Message {
        try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).model(token: "tok")
    }

    private func message(id: Int, threadID: Int?, extra: String = "") -> String {
        """
        {"id":\(id),"token":"tok","actorType":"users","actorId":"alice","timestamp":1757700000,
         "message":"hi","messageParameters":[],"messageType":"comment","reactions":[]\
        \(threadID.map { ",\"threadId\":\($0)" } ?? "")\(extra)}
        """
    }

    @Test("A thread's first message and its replies know the thread; everything else is in none")
    func decoding() throws {
        let root = try decode(message(id: 10, threadID: 10, extra: #","isThread":true,"threadTitle":"Plans","threadReplies":3"#))
        #expect(root.thread == MessageThread(id: 10, title: "Plans", replies: 3))
        #expect(root.isThreadRoot)

        let reply = try decode(message(id: 12, threadID: 10, extra: #","isThread":true,"threadTitle":"Plans","threadReplies":4"#))
        #expect(reply.thread?.id == 10)
        #expect(!reply.isThreadRoot)

        // Every message has a threadId — its own — without being in a thread.
        let plain = try decode(message(id: 13, threadID: 13))
        #expect(plain.thread == nil)
        #expect(!plain.isThreadRoot)
        #expect(try decode(message(id: 14, threadID: nil)).thread == nil)
    }

    @Test("A cached message from before threads still reads")
    func oldCache() throws {
        let message = Message(messageID: 1, token: "tok", actor: MessageActor(kind: .users, id: "a"), timestamp: .now, text: "hi")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object["thread"] = nil
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.thread == nil)
        #expect(decoded.text == "hi")
    }

    @Test("A thread's reply count is the newest of its messages'")
    func replyCounts() {
        func message(_ id: Int, thread: Int?, replies: Int) -> Message {
            Message(messageID: id, token: "tok", actor: MessageActor(kind: .users, id: "a"), timestamp: .now, text: "",
                    thread: thread.map { MessageThread(id: $0, title: "T", replies: replies) })
        }
        let counts = MessageThread.replyCounts(in: [
            message(10, thread: 10, replies: 1),
            message(15, thread: 10, replies: 5),
            message(12, thread: 10, replies: 2),
            message(20, thread: 20, replies: 0),
            message(21, thread: nil, replies: 9),
            message(0, thread: 10, replies: 99),
        ])
        #expect(counts == [10: 5, 20: 0])
    }

    @Test("Thread info decodes the thread, this user's notifications and its first message")
    func threadInfo() throws {
        let json = """
        {"thread":{"id":10,"roomToken":"tok","title":"Plans","lastMessageId":15,"lastActivity":1757700100,"numReplies":4},
         "attendee":{"notificationLevel":2},
         "first":{"id":10,"token":"tok","actorType":"users","actorId":"alice","timestamp":1757700000,"message":"Let's plan","messageParameters":[],"messageType":"comment","reactions":[],"threadId":10,"isThread":true,"threadTitle":"Plans","threadReplies":4},
         "last":null}
        """
        let summary = try JSONDecoder().decode(ThreadInfoDTO.self, from: Data(json.utf8)).model(token: "x")
        #expect(summary.id == 10)
        #expect(summary.token == "tok")
        #expect(summary.title == "Plans")
        #expect(summary.replies == 4)
        #expect(summary.notificationLevel == .mentions)
        #expect(summary.first?.text == "Let's plan")
        #expect(summary.last == nil)
    }
}
