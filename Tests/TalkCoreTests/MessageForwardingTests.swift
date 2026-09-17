import Foundation
import Testing
@testable import TalkCore

@Suite("Forwarding")
struct MessageForwardingTests {
    private let bob = MessageActor(kind: .users, id: "bob", displayName: "Bob")

    private func message(_ text: String, _ parameters: [String: RichObject] = [:], kind: MessageKind = .comment) -> Message {
        Message(messageID: 7, token: "g", actor: bob, timestamp: Date(), kind: kind, text: text, parameters: parameters)
    }

    @Test("Words are posted again, with mentions written out as plain text")
    func text() {
        let carol = RichObject(type: .user, id: "carol", name: "Carol Cortez")
        let plan = ForwardPlan.plan(for: message("Ask {mention-user1} about **the plan**", ["mention-user1": carol]))
        #expect(plan == .text("Ask @Carol Cortez about **the plan**"))
    }

    @Test("A file is shared again from its path, with its caption and without its placeholder")
    func file() {
        let file = RichObject(type: .file, id: "3", name: "plan.pdf", attributes: ["path": "Talk/plan.pdf", "mimetype": "application/pdf"])
        #expect(ForwardPlan.plan(for: message("{file}", ["file": file])) == .file(path: "Talk/plan.pdf", caption: "", isVoiceMessage: false))
        #expect(ForwardPlan.plan(for: message("Here it is", ["file": file])) == .file(path: "Talk/plan.pdf", caption: "Here it is", isVoiceMessage: false))
        let voice = message("{file}", ["file": file], kind: .voiceMessage)
        #expect(ForwardPlan.plan(for: voice) == .file(path: "Talk/plan.pdf", caption: "", isVoiceMessage: true))
    }

    @Test("Polls, system lines and deleted messages aren't forwarded")
    func notForwarded() {
        let poll = RichObject(type: .talkPoll, id: "1", name: "Lunch?")
        #expect(ForwardPlan.plan(for: message("{object}", ["object": poll])) == nil)
        #expect(ForwardPlan.plan(for: message("{actor} joined", kind: .system)) == nil)
        var deleted = message("gone")
        deleted.isDeleted = true
        #expect(ForwardPlan.plan(for: deleted) == nil)
        #expect(ForwardPlan.plan(for: message("   ")) == nil)
    }
}
