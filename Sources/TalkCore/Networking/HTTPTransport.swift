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

    /// Seconds only — the legal HTTP-date form yields `nil` rather than a guess.
    ///
    /// Whatever comes back is still the server's number, so it is only ever a suggestion;
    /// ``Backoff/delay(forAttempt:after:)`` is where it is clamped. Values that are not a
    /// finite, non-negative count of seconds are dropped here, because `TimeInterval("nan")`
    /// and `TimeInterval("-1")` both parse and neither means anything.
    var retryAfter: TimeInterval? {
        guard let raw = self["retry-after"],
              let seconds = TimeInterval(raw),
              seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
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
    /// A body read from disk by the transport as it sends, in place of ``body``.
    ///
    /// For attachments. A file on a wedged network mount blocks its read indefinitely, so
    /// the transport reads it on a thread of its own and abandons a read that stops
    /// answering — see ``FileBodyPump``. The file is never held in memory whole.
    var bodyFile: URL?
    /// Long polls need a much longer timeout than ordinary calls.
    var timeout: TimeInterval = 30
    /// How many bytes of response body the transport will accumulate before giving up.
    ///
    /// Without a ceiling the only bound on a response is the resource timeout, so a server
    /// that simply keeps writing takes the app down — and since the chat long poll restarts
    /// itself, it can do it again on every launch. The default is the generous one because
    /// a download is as big as the user's file; ``OCSClient`` drops API calls to
    /// ``apiResponseLimit``.
    var maximumResponseSize: Int = HTTPRequest.transferResponseLimit

    /// Ample for any OCS payload this client asks for. The largest is a 100-message chat
    /// page, which at Talk's 32 000-character message limit cannot plausibly reach this.
    static let apiResponseLimit = 16 * 1024 * 1024
    /// A file the user asked for. Still bounded: the body is held in memory as `Data`.
    static let transferResponseLimit = 128 * 1024 * 1024
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

    /// Sends a request whose body is a file, reporting 0…1 as the bytes go out.
    ///
    /// Separate from ``send(_:)`` because an upload is the one case where a progress bar is
    /// worth the plumbing — and because the default implementation below means a transport
    /// only implements it if it can do better than "0, then 1".
    func upload(
        _ request: HTTPRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> HTTPResponse
}

extension HTTPTransport {
    func upload(
        _ request: HTTPRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> HTTPResponse {
        progress(0)
        let response = try await send(request)
        progress(1)
        return response
    }
}
