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

@Suite("Recipient matching")
struct RecipientMatchingTests {
    private func entry(_ id: String, _ label: String, subline: String? = nil) -> DirectoryEntry {
        DirectoryEntry(identifier: id, label: label, source: .users, subline: subline)
    }

    private let known = [
        DirectoryEntry(identifier: "heine", label: "Heine Volder Rødder", source: .users),
        DirectoryEntry(identifier: "lea", label: "Lea Hansen", source: .users),
        DirectoryEntry(identifier: "marianne", label: "Marianne Grøn", source: .users)
    ]

    @Test("Letters merely in order find someone the server's matching would not")
    func initialsMatchLocally() {
        // The server matches prefixes and substrings, so it answers nothing for "hvr".
        let matches = DirectoryEntry.matches(for: "hvr", server: [], known: known)
        #expect(matches.map(\.identifier) == ["heine"])
    }

    @Test("Spaces in what was typed are not required of the name")
    func spacedInitials() {
        #expect(DirectoryEntry.matches(for: "h v r", server: [], known: known).first?.identifier == "heine")
    }

    @Test("Accents are not required, and neither are the Danish letters")
    func foldsDiacritics() {
        // "Grøn" typed without the stroke. Folding alone does not do this: ø is a letter in
        // its own right, not an o with something on it, so there is no mark to strip.
        #expect(DirectoryEntry.matches(for: "gron", server: [], known: known).first?.identifier == "marianne")
        #expect(DirectoryEntry.matches(for: "rodder", server: [], known: known).first?.identifier == "heine")
        // And the ones folding does reach, still.
        let jerome = [DirectoryEntry(identifier: "j", label: "Jérôme Aubert", source: .users)]
        #expect(DirectoryEntry.matches(for: "jerome", server: [], known: jerome).count == 1)
    }

    @Test("A server result the grading cannot explain is kept, not dropped")
    func serverResultsSurvive() {
        // The server knows things this does not — who you talk to, who shares a team with
        // you — so a result it sent is shown even when nothing about the letters lines up.
        let fromServer = [entry("zz", "Someone Else")]
        let matches = DirectoryEntry.matches(for: "hvr", server: fromServer, known: known)
        #expect(matches.contains { $0.identifier == "zz" })
        // Behind the one that actually matches, though.
        #expect(matches.first?.identifier == "heine")
    }

    @Test("Someone already chosen is not offered again")
    func excludesChosen() {
        let matches = DirectoryEntry.matches(
            for: "he",
            server: [entry("heine", "Heine Volder Rødder")],
            known: known,
            excluding: [known[0]]
        )
        #expect(matches.contains { $0.identifier == "heine" } == false)
    }

    @Test("The same person from both sources appears once")
    func dedupes() {
        let matches = DirectoryEntry.matches(
            for: "heine",
            server: [entry("heine", "Heine Volder Rødder")],
            known: known
        )
        #expect(matches.filter { $0.identifier == "heine" }.count == 1)
    }

    @Test("A better match outranks a worse one")
    func ordering() {
        let people = [
            DirectoryEntry(identifier: "a", label: "Alexander Lea", source: .users),   // substring
            DirectoryEntry(identifier: "b", label: "Lea Hansen", source: .users)       // prefix
        ]
        #expect(DirectoryEntry.matches(for: "lea", server: [], known: people).map(\.identifier) == ["b", "a"])
    }
}
