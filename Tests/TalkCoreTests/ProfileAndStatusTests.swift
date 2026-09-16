import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TalkCore

@Suite("Profile and status")
struct ProfileAndStatusTests {
    private let server = try! ServerAddress.parse("https://cloud.example.com")
    private let credentials = Credentials(loginName: "alice", appPassword: "pw")

    private func client(_ transport: StubTransport) -> OCSClient {
        OCSClient(server: server, credentials: credentials, transport: transport)
    }

    private func envelope(_ data: String, status: Int = 200) -> String {
        #"{"ocs":{"meta":{"status":"ok","statuscode":\#(status),"message":"OK"},"data":\#(data)}}"#
    }

    private func form(_ request: HTTPRequest?) -> [String: String] {
        guard let body = request?.body, let text = String(data: body, encoding: .utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).removingPercentEncoding ?? "", String(parts[1]).removingPercentEncoding ?? "")
        })
    }

    // MARK: - Profile

    @Test("A profile keeps the fields that have a value, each with who can see it")
    func decodesProfile() async throws {
        let transport = StubTransport(json: envelope("""
        {"id":"alice","displayname":"Alice Liddell","displaynameScope":"v2-federated",
         "email":"alice@example.com","emailScope":"v2-local",
         "phone":"","phoneScope":"v2-private",
         "headline":"Down the rabbit hole","headlineScope":"v2-published",
         "biography":"Curious.\\nVery curious.","biographyScope":"contacts",
         "pronouns":"she/her",
         "website":"   ",
         "organisation":null,
         "profile_enabled":"1"}
        """))
        let service = ProfileService(server: server, credentials: credentials, userID: "alice", transport: transport, client: client(transport))

        let profile = try await service.profile()

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/cloud/users/alice")
        #expect(profile.displayName == "Alice Liddell")
        #expect(profile.isProfileEnabled)
        // Email, pronouns, headline, biography — in the Personal info page's order; the
        // empty phone, the blank website and the null organisation are left out.
        #expect(profile.fields.map(\.kind) == [.email, .pronouns, .headline, .biography])
        #expect(profile.field(.email)?.scope == .local)
        #expect(profile.field(.headline)?.scope == .published)
        #expect(profile.field(.biography)?.scope == .local, "an old server's scope name is still understood")
        #expect(profile.field(.pronouns)?.scope == nil)
    }

    @Test("A profile with nothing filled in is still a profile")
    func sparseProfile() throws {
        let data = Data(envelope(#"{"id":"bob"}"#).utf8)
        let decoded = try JSONDecoder().decode(OCSEnvelope<UserProfileDTO>.self, from: data)
        let profile = try #require(decoded.data).profile
        #expect(profile.displayName == "bob")
        #expect(profile.fields.isEmpty)
        #expect(!profile.isProfileEnabled)
    }

    // MARK: - Status

    @Test("Never having set a status is being online with no message")
    func noStatusYet() async throws {
        let transport = StubTransport(json: envelope("[]", status: 404), status: 404)
        let status = try await UserStatusService(client: client(transport)).status()
        #expect(status == .unset)
    }

    @Test("A status decodes with its message and when it clears")
    func decodesStatus() async throws {
        let transport = StubTransport(json: envelope("""
        {"userId":"alice","message":"Lunch","messageId":null,"messageIsPredefined":false,
         "icon":"🥪","clearAt":1750000000,"status":"dnd","statusIsUserDefined":true}
        """))
        let status = try await UserStatusService(client: client(transport)).status()
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/user_status/api/v1/user_status")
        #expect(status.status == .dnd)
        #expect(status.message == "Lunch")
        #expect(status.icon == "🥪")
        #expect(status.clearAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(status.hasMessage)
    }

    @Test("Each status change sends what the server expects")
    func statusRequests() async throws {
        let reply = envelope(#"{"userId":"alice","message":null,"icon":null,"clearAt":null,"status":"away","messageIsPredefined":false}"#)
        let transport = StubTransport(json: reply)
        let service = UserStatusService(client: client(transport))
        let clearAt = Date(timeIntervalSince1970: 1_750_003_600)

        _ = try await service.setStatus(.away)
        #expect(transport.lastRequest?.method == .put)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/user_status/api/v1/user_status/status")
        #expect(form(transport.lastRequest) == ["statusType": "away"])

        _ = try await service.setCustomMessage(icon: "🌴", message: "Back Monday", clearAt: clearAt)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/user_status/api/v1/user_status/message/custom")
        #expect(form(transport.lastRequest) == ["statusIcon": "🌴", "message": "Back Monday", "clearAt": "1750003600"])

        _ = try await service.setCustomMessage(icon: "", message: "Heads down", clearAt: nil)
        #expect(form(transport.lastRequest) == ["message": "Heads down"], "empty and absent values are left out, not sent empty")

        _ = try await service.setPredefinedMessage(id: "meeting", clearAt: clearAt)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/user_status/api/v1/user_status/message/predefined")
        #expect(form(transport.lastRequest) == ["messageId": "meeting", "clearAt": "1750003600"])

        try await service.clearMessage()
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/user_status/api/v1/user_status/message")
    }

    @Test("A refused status carries the server's reason")
    func refusedStatus() async throws {
        let transport = StubTransport(json: #"{"ocs":{"meta":{"status":"failure","statuscode":400,"message":"Message is too long"},"data":[]}}"#, status: 400)
        await #expect(throws: TalkError.ocs(status: 400, message: "Message is too long")) {
            _ = try await UserStatusService(client: client(transport)).setCustomMessage(icon: nil, message: "x", clearAt: nil)
        }
    }

    @Test("Ready-made messages decode with when they clear")
    func predefined() async throws {
        let transport = StubTransport(json: envelope("""
        [{"id":"meeting","icon":"📅","message":"In a meeting","clearAt":{"type":"period","time":3600}},
         {"id":"commuting","icon":"🚌","message":"Commuting","clearAt":{"type":"period","time":1800}},
         {"id":"sick-leave","icon":"🤒","message":"Out sick","clearAt":{"type":"end-of","time":"day"}},
         {"id":"vacationing","icon":"🌴","message":"Vacationing","clearAt":null},
         {"icon":"?","message":"no id, so not a status"}]
        """))
        let statuses = try await UserStatusService(client: client(transport)).predefinedStatuses()
        #expect(transport.lastRequest?.url.absoluteString == "https://cloud.example.com/ocs/v2.php/apps/user_status/api/v1/predefined_statuses/")
        #expect(statuses.map(\.id) == ["meeting", "commuting", "sick-leave", "vacationing"])
        #expect(statuses.map(\.clearAfter) == [.oneHour, .thirtyMinutes, .today, .never])
    }

    @Test("Clear-after times land where the calendar says")
    func clearAfterDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Copenhagen"))
        calendar.firstWeekday = 2
        // Wednesday 16 September 2026, 10:00 in Copenhagen.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 10)))

        #expect(ClearAfter.never.date(from: now, calendar: calendar) == nil)
        #expect(ClearAfter.oneHour.date(from: now, calendar: calendar) == now.addingTimeInterval(3600))
        #expect(ClearAfter.today.date(from: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        #expect(ClearAfter.thisWeek.date(from: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2026, month: 9, day: 21)))
    }

    @Test("Status support comes from the capabilities, and a bad status section costs nothing else")
    func capabilities() throws {
        func parse(_ userStatus: String) throws -> TalkCapabilities {
            let json = envelope(#"{"version":{"major":31},"capabilities":{"spreed":{"features":["chat-v2"]},"user_status":\#(userStatus)}}"#)
            let dto = try #require(try JSONDecoder().decode(OCSEnvelope<CapabilitiesDTO>.self, from: Data(json.utf8)).data)
            return try #require(dto.talkCapabilities())
        }

        #expect(try parse(#"{"enabled":true,"restore":true,"supports_emoji":true,"supports_busy":true}"#).userStatus
                == UserStatusSupport(supportsEmoji: true, supportsBusy: true))
        #expect(try parse(#"{"enabled":true,"supports_emoji":true}"#).userStatus?.supportsBusy == false)
        #expect(try parse(#"{"enabled":false}"#).userStatus == nil)
        let malformed = try parse(#""surprise""#)
        #expect(malformed.userStatus == nil)
        #expect(malformed.supportsChat)
    }

    // MARK: - Picture

    @Test("A picture goes up as multipart, with the header that passes the CSRF check")
    func uploadsAvatar() async throws {
        let transport = StubTransport(json: #"{"status":"success"}"#)
        let service = ProfileService(server: server, credentials: credentials, userID: "alice", transport: transport, client: client(transport))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        try await service.setAvatar(png: png)

        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://cloud.example.com/index.php/avatar/")
        #expect(request.headers["OCS-APIRequest"] == "true")
        #expect(request.headers["Authorization"] == credentials.authorizationHeaderValue)
        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

        let body = try #require(request.body)
        #expect(body.range(of: png) != nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--\(boundary)\r\n"))
        #expect(text.contains(#"Content-Disposition: form-data; name="files[]"; filename="avatar.png""#))
        #expect(text.contains("Content-Type: image/png"))
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    @Test("A refused picture says why, in Nextcloud's words", arguments: [
        (400, #"{"data":{"message":"File is too big"}}"#, "File is too big"),
        (200, #"{"data":{"message":"Unknown filetype"}}"#, "Unknown filetype"),
        (200, #"{"status":"error","data":{"message":"Invalid image"}}"#, "Invalid image")
    ])
    func refusedAvatar(_ input: (Int, String, String)) async throws {
        let transport = StubTransport(json: input.1, status: input.0)
        let service = ProfileService(server: server, credentials: credentials, userID: "alice", transport: transport, client: client(transport))
        await #expect(throws: TalkError.ocs(status: input.0, message: input.2)) {
            try await service.setAvatar(png: Data([1]))
        }
    }

    @Test("Removing the picture is a DELETE, and an empty answer is success")
    func removesAvatar() async throws {
        let transport = StubTransport(json: "")
        let service = ProfileService(server: server, credentials: credentials, userID: "alice", transport: transport, client: client(transport))
        try await service.removeAvatar()
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.absoluteString == "https://cloud.example.com/index.php/avatar/")
        #expect(transport.lastRequest?.headers["OCS-APIRequest"] == "true")
    }

    // MARK: - Links

    @Test("Browser links come from the signed-in address, including a subdirectory install")
    func links() throws {
        let links = ProfileLinks(server: try ServerAddress.parse("https://example.com/nextcloud"), userID: "alice/../admin")
        #expect(links.personalInfo.absoluteString == "https://example.com/nextcloud/index.php/settings/user")
        #expect(links.security.absoluteString == "https://example.com/nextcloud/index.php/settings/user/security")
        // A user id can't walk the profile link somewhere else.
        #expect(links.publicProfile.path == "/nextcloud/index.php/u/alice_.._admin")
    }

    // MARK: - Square crop

    private func image(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func size(of png: Data) throws -> (Int, Int, String?) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int),
            CGImageSourceGetType(source) as String?
        )
    }

    @Test("Any picture becomes a square PNG, no larger than it needs to be", arguments: [
        (1200, 800, 512), (600, 2000, 512), (300, 300, 300), (100, 40, 40)
    ])
    func squares(_ input: (Int, Int, Int)) throws {
        let png = try SquareAvatar.png(from: try image(width: input.0, height: input.1))
        let (width, height, type) = try size(of: png)
        #expect(width == input.2)
        #expect(height == input.2)
        #expect(type == UTType.png.identifier)
    }

    @Test("Something that isn't a picture is refused")
    func notAPicture() {
        #expect(throws: SquareAvatar.Failure.notAnImage) {
            _ = try SquareAvatar.png(from: Data("not an image".utf8))
        }
    }
}
