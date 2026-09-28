import Foundation
import Testing
@testable import TalkCore

@Suite("Summary input")
struct SummaryInputTests {
    private func message(_ id: Int, _ who: String, _ text: String, system: String = "", deleted: Bool = false) -> Message {
        Message(messageID: id, token: "tok", actor: MessageActor(kind: .users, id: who.lowercased(), displayName: who),
                timestamp: .now, systemMessage: system, text: text, isDeleted: deleted)
    }

    @Test("Only people's words from the first unread on, each with who said it")
    func lines() {
        let messages = [
            message(1, "Lea", "old"),
            message(2, "Heine", "Shall we meet Friday?"),
            message(3, "System", "", system: "call_started"),
            message(4, "Lea", "gone", deleted: true),
            message(5, "Lea", "   "),
            message(6, "Lea", "Friday works"),
        ]
        let lines = SummaryInput.lines(from: messages, startingAt: 2) { $0.text }
        #expect(lines == [.init(author: "Heine", text: "Shall we meet Friday?"), .init(author: "Lea", text: "Friday works")])
    }

    @Test("A long message is cut short")
    func longMessage() {
        let long = String(repeating: "a", count: 1_000)
        let lines = SummaryInput.lines(from: [message(1, "Lea", long)], startingAt: 1) { $0.text }
        #expect(lines.first?.text.count == SummaryInput.messageLimit + 1)
    }

    @Test("When it doesn't all fit, the newest lines are kept, in order")
    func budget() {
        let lines = (1...5).map { SummaryInput.Line(author: "A", text: "message \($0)") }
        let (text, included) = SummaryInput.transcript(lines, budget: 40)
        #expect(included == 3)
        #expect(text == "A: message 3\nA: message 4\nA: message 5")
        #expect(SummaryInput.transcript(lines, budget: 5).included == 1)
    }

    @Test("A long stretch is cut into chunks that each fit, in order, keeping the newest")
    func chunks() {
        let lines = (1...10).map { SummaryInput.Line(author: "A", text: String(repeating: "x", count: 20) + "\($0)") }
        // Each rendered line is 3 + 21 or 22 characters, plus a newline: three to a 80-character chunk.
        let chunks = SummaryInput.chunks(lines, budget: 80)
        #expect(chunks.count == 4)
        #expect(chunks.first?.hasPrefix("A: ") == true)
        #expect(chunks.joined(separator: "\n").components(separatedBy: "\n").count == 10)
        #expect(chunks.last?.hasSuffix("x10") == true)

        let capped = SummaryInput.chunks(lines, budget: 80, maximum: 2)
        #expect(capped.count == 2)
        #expect(capped.last?.hasSuffix("x10") == true)
        #expect(capped.first?.contains("x7") == true)
    }

    @Test("One line longer than a chunk still gets a chunk of its own")
    func oversizedLine() {
        let lines = [SummaryInput.Line(author: "A", text: String(repeating: "y", count: 200)), SummaryInput.Line(author: "B", text: "short")]
        #expect(SummaryInput.chunks(lines, budget: 50).count == 2)
    }
}
