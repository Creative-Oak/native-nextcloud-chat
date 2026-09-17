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

@Suite("Out of office")
struct AbsenceServiceTests {
    @Test("A current absence decodes, with who to ask instead")
    func current() async throws {
        let json = """
        {"id":"12","userId":"bob","startDate":1757887200,"endDate":1758232800,"shortMessage":"On holiday",
         "message":"Back on Monday. Ask Carol for anything urgent.","replacementUserId":"carol","replacementUserDisplayName":"Carol Cortez"}
        """
        let transport = StubTransport(json: ocsEnvelope(json))
        let absence = try #require(try await AbsenceService(client: try client(transport)).currentAbsence(userID: "bob"))

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/dav/api/v1/outOfOffice/bob/now")
        #expect(absence.shortMessage == "On holiday")
        #expect(absence.replacementUserID == "carol")
        #expect(absence.replacementDisplayName == "Carol Cortez")
        #expect(Endpoint.redacted(Endpoint.outOfOfficeNow("bob")) == "/ocs/v2.php/apps/dav/api/v1/outOfOffice/…/now")
    }

    @Test("Not away is nil, not an error")
    func notAway() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]", statuscode: 404), status: 404)
        #expect(try await AbsenceService(client: try client(transport)).currentAbsence(userID: "bob") == nil)
    }

    @Test("An absence ending at midnight lasts until the day before")
    func lastDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Copenhagen"))
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21)))
        let absence = Absence(userID: "bob", start: midnight.addingTimeInterval(-5 * 86_400), end: midnight,
                              shortMessage: "", message: "")
        #expect(calendar.component(.day, from: absence.lastDay(calendar: calendar)) == 20)
    }
}
