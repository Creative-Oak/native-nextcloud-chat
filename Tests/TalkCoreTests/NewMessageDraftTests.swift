import Foundation
import Testing
@testable import TalkCore

private func person(_ id: String, _ label: String) -> DirectoryEntry {
    DirectoryEntry(identifier: id, label: label, source: .users)
}

private func group(_ id: String, _ label: String) -> DirectoryEntry {
    DirectoryEntry(identifier: id, label: label, source: .groups)
}

@Suite("New Message draft")
struct NewMessageDraftTests {
    // MARK: - What the recipients add up to

    @Test("Nobody is not a conversation yet")
    func noRecipients() {
        #expect(NewConversation.draft(recipients: [], isOpen: false) == nil)
        #expect(NewConversation.draft(recipients: [], isOpen: true) == nil)
    }

    @Test("One person is a one-to-one, which Talk hands back if you already have it")
    func onePerson() {
        let draft = NewConversation.draft(recipients: [person("heine", "Heine")], isOpen: false)
        #expect(draft?.type == .oneToOne)
        // Talk names a one-to-one itself, from whoever is in it.
        #expect(draft?.name.isEmpty == true)
        #expect(draft?.participants == ["users": ["heine"]])
    }

    @Test("One group is still a group — Talk cannot make a one-to-one with one")
    func oneGroup() {
        // The case a count alone gets wrong: `createOneToOneRoom` looks its invitee up in the
        // user manager, so a group there fails at the server with `invite`.
        let draft = NewConversation.draft(recipients: [group("design", "Design")], isOpen: false)
        #expect(draft?.type == .group)
        #expect(draft?.participants == ["groups": ["design"]])
    }

    @Test("Two or more people are a group")
    func severalPeople() {
        let draft = NewConversation.draft(
            recipients: [person("heine", "Heine"), person("lea", "Lea")],
            isOpen: false
        )
        #expect(draft?.type == .group)
        #expect(draft?.participants == ["users": ["heine", "lea"]])
    }

    @Test("Open beats the count, because a one-to-one cannot be public")
    func openOverridesCount() {
        let draft = NewConversation.draft(recipients: [person("heine", "Heine")], isOpen: true)
        #expect(draft?.type == .publicRoom)
        // And so it needs a name, where the one-to-one did not.
        #expect(draft?.name == "Heine")
    }

    @Test("People and groups together are sorted into the sources Talk expects")
    func mixedSources() {
        let draft = NewConversation.draft(
            recipients: [person("heine", "Heine"), group("design", "Design"), person("lea", "Lea")],
            isOpen: false
        )
        #expect(draft?.participants["users"] == ["heine", "lea"])
        #expect(draft?.participants["groups"] == ["design"])
    }

    // MARK: - The name Talk insists on

    @Test("A group is named after the people in it", arguments: [
        (["Heine"], "Heine"),
        (["Heine", "Lea"], "Heine & Lea"),
        (["Heine", "Lea", "Marianne"], "Heine, Lea & Marianne"),
        (["Heine", "Lea", "Marianne", "Mor"], "Heine, Lea, Marianne & 1 more"),
        (["Heine", "Lea", "Marianne", "Mor", "Steffen"], "Heine, Lea, Marianne & 2 more")
    ])
    func derivedNames(_ input: ([String], String)) {
        let recipients = input.0.map { person($0.lowercased(), $0) }
        #expect(NewConversation.name(for: recipients) == input.1)
    }

    @Test("A recipient with no usable label doesn't produce a nameless group")
    func blankLabels() {
        // Talk calls a nameless group "---", which is worse than anything we could pick.
        #expect(NewConversation.name(for: [person("a", "   ")]) == "New Conversation")
        #expect(NewConversation.name(for: []) == "New Conversation")
        // One blank among several drops out rather than leaving a gap in the list.
        #expect(NewConversation.name(for: [person("a", "Heine"), person("b", " ")]) == "Heine")
    }

    // MARK: - The reserved token

    @Test("The draft's stand-in token can never be a real one")
    func draftTokenIsReserved() {
        // A Talk token is 8 characters of [a-z0-9]; this is neither that shape nor that
        // alphabet, so a draft can never be mistaken for a conversation.
        #expect(ConversationDraftToken.value.contains(where: { !$0.isLowercase && !$0.isNumber }))
        #expect(ConversationDraftToken.isDraft(ConversationDraftToken.value))
        #expect(ConversationDraftToken.isDraft("a1b2c3d4") == false)
    }
}
