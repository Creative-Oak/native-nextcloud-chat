import Foundation
import Testing
@testable import TalkCore

@Suite("Capability parsing")
struct CapabilityTests {
    private func parse(_ data: Data) throws -> TalkCapabilities {
        let envelope = try JSONDecoder().decode(OCSEnvelope<CapabilitiesDTO>.self, from: data)
        let dto = try #require(envelope.data)
        return try #require(dto.talkCapabilities())
    }

    @Test("Parses a real Talk 21 capabilities response")
    func parsesFixture() throws {
        let capabilities = try parse(try Fixture.data("capabilities"))

        #expect(capabilities.talkVersion == "21.0.4")
        #expect(capabilities.serverVersion.string == "31.0.4")
        #expect(capabilities.serverVersion.major == 31)

        #expect(capabilities.supportsChat)
        #expect(capabilities.supportsReactions)
        #expect(capabilities.canEditMessages)
        #expect(capabilities.canDeleteMessages)
        #expect(capabilities.supportsReferenceIDs)
        #expect(capabilities.canSetReadMarker)
        #expect(capabilities.canMarkUnread)
        #expect(capabilities.supportsDirectMentionFlag)
        #expect(capabilities.supportsConversationAvatars)
        #expect(capabilities.supportsNoteToSelf)
        #expect(capabilities.supportsMarkdown)
        #expect(capabilities.supportsFederation)

        // Talk 19 removed the deletion time limit.
        #expect(capabilities.deletionIsTimeLimited == false)

        #expect(capabilities.config.effectiveMaxMessageLength == 32_000)
        #expect(capabilities.config.readReceiptsAreMeaningful)   // read-privacy 0 == public
        #expect(capabilities.attachmentsAllowed)
        #expect(capabilities.config.attachmentsFolder == "/Talk")
        #expect(capabilities.canCreateConversations)
    }

    @Test("features-local counts the same as features for local conversations")
    func mergesLocalFeatures() throws {
        let capabilities = try parse(try Fixture.data("capabilities"))
        #expect(capabilities.showsReadStatus)
    }

    @Test("An old server degrades feature by feature instead of failing")
    func oldServer() throws {
        let json = ocsEnvelope("""
        {"version":{"major":20,"minor":0,"micro":1,"string":"20.0.1","edition":""},
         "capabilities":{"spreed":{"features":["chat-v2","chat-read-marker","delete-messages"],
         "config":{"chat":{"max-length":1000}},"version":"11.3.0"}}}
        """)
        let capabilities = try parse(Data(json.utf8))

        #expect(capabilities.supportsChat)
        #expect(capabilities.canSetReadMarker)
        #expect(capabilities.canDeleteMessages)
        // …and the six-hour window still applies, because delete-messages-unlimited is absent.
        #expect(capabilities.deletionIsTimeLimited)

        #expect(capabilities.supportsReactions == false)
        #expect(capabilities.canEditMessages == false)
        #expect(capabilities.canMarkUnread == false)
        #expect(capabilities.supportsReferenceIDs == false)
        #expect(capabilities.config.effectiveMaxMessageLength == 1000)
        // Absent config: fall back to Talk's own defaults rather than disabling everything.
        #expect(capabilities.canCreateConversations)
        #expect(capabilities.attachmentsAllowed == false)
    }

    @Test("A server without Talk is recognised, not mis-parsed")
    func noTalkInstalled() throws {
        let json = ocsEnvelope(#"{"version":{"major":31,"minor":0,"micro":0,"string":"31.0.0","edition":""},"capabilities":{"files":{"undelete":true}}}"#)
        let envelope = try JSONDecoder().decode(OCSEnvelope<CapabilitiesDTO>.self, from: Data(json.utf8))
        #expect(try #require(envelope.data).talkCapabilities() == nil)
    }

    @Test("Config scalars survive being sent as strings")
    func lenientScalars() throws {
        let json = ocsEnvelope("""
        {"capabilities":{"spreed":{"features":["chat-v2"],
         "config":{"chat":{"max-length":"8000","read-privacy":"1"},
                   "attachments":{"allowed":"1","folder":"/Talk"},
                   "conversations":{"can-create":0}},
         "version":"18.0.0"}}}
        """)
        let capabilities = try parse(Data(json.utf8))
        #expect(capabilities.config.effectiveMaxMessageLength == 8000)
        #expect(capabilities.config.readReceiptsAreMeaningful == false)
        #expect(capabilities.attachmentsAllowed)
        #expect(capabilities.canCreateConversations == false)
    }

    @Test("Unknown capability strings are kept, so a newer server isn't flattened")
    func keepsUnknownFeatures() throws {
        let json = ocsEnvelope(#"{"capabilities":{"spreed":{"features":["chat-v2","some-future-thing"],"version":"99.0.0"}}}"#)
        let capabilities = try parse(Data(json.utf8))
        #expect(capabilities.has("some-future-thing"))
    }

    @Test("Deletion window is enforced locally only when the server still enforces it")
    func deletionWindow() throws {
        let now = Date()
        let fresh = Message(messageID: 1, token: "t", actor: MessageActor(kind: .users, id: "alice"),
                            timestamp: now.addingTimeInterval(-60), text: "hi")
        let old = Message(messageID: 2, token: "t", actor: MessageActor(kind: .users, id: "alice"),
                          timestamp: now.addingTimeInterval(-7 * 3600), text: "hi")

        let limited = TalkCapabilities(features: ["chat-v2", "delete-messages"])
        #expect(limited.canDelete(fresh, now: now))
        #expect(limited.canDelete(old, now: now) == false)

        let unlimited = TalkCapabilities(features: ["chat-v2", "delete-messages", "delete-messages-unlimited"])
        #expect(unlimited.canDelete(old, now: now))

        let none = TalkCapabilities(features: ["chat-v2"])
        #expect(none.canDelete(fresh, now: now) == false)
    }
}
