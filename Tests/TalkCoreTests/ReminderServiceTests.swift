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

@Suite("Reminders")
struct ReminderServiceTests {
    @Test("Setting a reminder posts its time in seconds; removing it is a DELETE")
    func setAndDelete() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"messageId":41,"timestamp":1757700000,"token":"tok","userId":"alice"}"#, statuscode: 201))
        let service = ReminderService(client: try client(transport))

        try await service.setReminder(token: "tok", messageID: 41, at: Date(timeIntervalSince1970: 1_757_700_000))
        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/41/reminder")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self) == "timestamp=1757700000")

        try await service.deleteReminder(token: "tok", messageID: 41)
        #expect(transport.lastRequest?.method == .delete)
        #expect(Endpoint.redacted(Endpoint.reminder("tok", 41)) == "/ocs/v2.php/apps/spreed/api/v1/chat/…/…/reminder")
    }

    @Test("The upcoming list decodes, soonest first, with the message it quotes")
    func upcoming() async throws {
        let json = """
        [
          {"roomToken":"b","messageId":9,"reminderTimestamp":1757800000,"actorType":"users","actorId":"carol",
           "actorDisplayName":"Carol","message":"Later","messageParameters":[]},
          {"roomToken":"a","messageId":7,"reminderTimestamp":1757700000,"actorType":"users","actorId":"bob",
           "actorDisplayName":"Bob","message":"See {file}","messageParameters":{"file":{"type":"file","id":"3","name":"plan.pdf"}}}
        ]
        """
        let transport = StubTransport(json: ocsEnvelope(json))
        let reminders = try await ReminderService(client: try client(transport)).upcoming()

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/upcoming-reminders")
        #expect(reminders.map(\.id) == ["a/7", "b/9"])
        #expect(reminders[0].actor.displayName == "Bob")
        #expect(reminders[0].parameters["file"]?.name == "plan.pdf")
        #expect(reminders[1].parameters.isEmpty)
    }

    @Test("Presets: Later Today only while the evening is still an hour off, and Next Week is never today")
    func presets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Copenhagen"))
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }

        // Wednesday 16 September 2026, 10:00.
        let morning = ReminderPreset.presets(now: at(2026, 9, 16, 10), calendar: calendar)
        #expect(morning.map(\.title) == ["In 30 Minutes", "In 1 Hour", "In 3 Hours", "Later Today", "Tomorrow", "Next Week"])
        #expect(morning.first { $0.title == "Later Today" }?.date == at(2026, 9, 16, 18))
        #expect(morning.first { $0.title == "Tomorrow" }?.date == at(2026, 9, 17, 9))
        #expect(morning.first { $0.title == "Next Week" }?.date == at(2026, 9, 21, 9))

        // 17:30 is too close to six to call six "later".
        #expect(!ReminderPreset.presets(now: at(2026, 9, 16, 17, 30), calendar: calendar).contains { $0.title == "Later Today" })

        // Monday 21 September, 08:00: next week is the Monday after, not an hour from now.
        let monday = ReminderPreset.presets(now: at(2026, 9, 21, 8), calendar: calendar)
        #expect(monday.first { $0.title == "Next Week" }?.date == at(2026, 9, 28, 9))
    }
}
