import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

/// Case-insensitive header bag. HTTP header names are case-insensitive and servers
/// are inconsistent about `X-Chat-Last-Given` vs `x-chat-last-given`; getting this
/// wrong silently breaks pagination, so it is handled once, here.
struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private var storage: [String: String] = [:]

    init() {}

    init(_ dictionary: [String: String]) {
        for (key, value) in dictionary { storage[key.lowercased()] = value }
    }

    init(dictionaryLiteral elements: (String, String)...) {
        for (key, value) in elements { storage[key.lowercased()] = value }
    }

    subscript(name: String) -> String? {
        get { storage[name.lowercased()] }
        set { storage[name.lowercased()] = newValue }
    }

    var all: [String: String] { storage }

    func int(_ name: String) -> Int? { self[name].flatMap(Int.init) }

    var retryAfter: TimeInterval? {
        guard let raw = self["retry-after"] else { return nil }
        return TimeInterval(raw)
    }

    var isMaintenanceMode: Bool { self["x-nextcloud-maintenance-mode"] == "1" }

    /// SHA1 of the server's Talk configuration. A change means capabilities must be re-fetched.
    var talkHash: String? { self["x-nextcloud-talk-hash"] }

    /// Echo back as the next `modifiedSince` so we track the server's clock, not ours.
    var talkModifiedBefore: Int? { int("x-nextcloud-talk-modified-before") }

    var chatLastGiven: Int? { int("x-chat-last-given") }

    var chatLastCommonRead: Int? { int("x-chat-last-common-read") }
}

struct HTTPRequest: Sendable {
    var method: HTTPMethod = .get
    var url: URL
    var headers: HTTPHeaders = .init()
    var body: Data?
    /// Long polls need a much longer timeout than ordinary calls.
    var timeout: TimeInterval = 30
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: HTTPHeaders
    var body: Data
}

/// The single seam between this client and the network.
///
/// Everything above this protocol is testable without a server, which is why the OCS
/// layer, the services and the sync engines all have real unit tests.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse
}
