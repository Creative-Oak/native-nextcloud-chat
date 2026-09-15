import Foundation
import Testing
@testable import TalkCore

private let alice = Credentials(loginName: "alice", appPassword: "secret")
private struct Boom: Error {}

/// The upgrade path off the legacy file keychain.
///
/// ``KeychainStore`` itself is not testable here and never will be: it lives behind
/// `#if canImport(Security)`, the Linux job only *parses* it, and a real Keychain is not
/// something a unit test can stand up. What is testable — and what the defect was actually
/// about — is the ordering, which is why it sits in ``LegacyCredentialMigration`` rather
/// than inline in the store. That the helper is wired to the right `SecItem…` calls, with
/// the data-protection key on the new place and off the old one, is verified by reading.
@Suite("Legacy credential migration")
struct CredentialMigrationTests {
    @Test("A credential in the current place is returned, and the old place is left alone")
    func currentWins() throws {
        var lookedAtLegacy = false
        var adopted = false
        let result = try LegacyCredentialMigration.read(
            current: { alice },
            legacy: {
                lookedAtLegacy = true
                return nil
            },
            adopt: { _ in adopted = true },
            forget: { },
            report: { _ in }
        )

        #expect(result == alice)
        #expect(!lookedAtLegacy)
        #expect(!adopted)
    }

    @Test("A credential found only in the old place is moved, not merely read")
    func legacyItemIsMoved() throws {
        // Reading it would have been enough to keep the user signed in, and that is the
        // trap: the item would still be somewhere no later delete or revoke can reach, so
        // the app password outlives the account for good. Moving it makes it ordinary.
        var adopted: Credentials?
        var forgotten = false
        let result = try LegacyCredentialMigration.read(
            current: { nil },
            legacy: { alice },
            adopt: { adopted = $0 },
            forget: { forgotten = true },
            report: { _ in }
        )

        #expect(result == alice)
        #expect(adopted == alice)
        #expect(forgotten)
    }

    @Test("A move that can’t be written leaves the only copy where it is")
    func failedWriteKeepsTheLegacyItem() throws {
        // Write first, delete second. The other order trades a reachable credential for no
        // credential at all the first time the new keychain refuses an add.
        var forgotten = false
        var reported = false
        let result = try LegacyCredentialMigration.read(
            current: { nil },
            legacy: { alice },
            adopt: { _ in throw Boom() },
            forget: { forgotten = true },
            report: { _ in reported = true }
        )

        #expect(result == alice)
        #expect(!forgotten)
        #expect(reported)
    }

    @Test("A copy that can’t be cleaned up is reported, not turned into a failed sign-in")
    func failedDeleteStillReturnsTheCredential() throws {
        var reported = false
        let result = try LegacyCredentialMigration.read(
            current: { nil },
            legacy: { alice },
            adopt: { _ in },
            forget: { throw Boom() },
            report: { _ in reported = true }
        )

        // Both copies exist now, which is untidy and harmless: the delete sweeps both
        // places, so sign-out still takes the leftover with it.
        #expect(result == alice)
        #expect(reported)
    }

    @Test("Nothing in either place is nothing, and nothing is written")
    func nothingAnywhere() throws {
        var adopted = false
        var forgotten = false
        let result = try LegacyCredentialMigration.read(
            current: { nil },
            legacy: { nil },
            adopt: { _ in adopted = true },
            forget: { forgotten = true },
            report: { _ in }
        )

        #expect(result == nil)
        #expect(!adopted)
        #expect(!forgotten)
    }

    @Test("A keychain that won’t open is not papered over with a look in the old one")
    func currentFailureIsNotSwallowed() {
        // "The keychain wouldn’t open" and "there is nothing here" want opposite answers,
        // and sign-out now depends on being able to tell them apart.
        var lookedAtLegacy = false
        var threw = false
        do {
            _ = try LegacyCredentialMigration.read(
                current: { throw Boom() },
                legacy: {
                    lookedAtLegacy = true
                    return alice
                },
                adopt: { _ in },
                forget: { },
                report: { _ in }
            )
        } catch is Boom {
            threw = true
        } catch {
        }

        #expect(threw)
        #expect(!lookedAtLegacy)
    }
}
