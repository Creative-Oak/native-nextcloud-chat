import Foundation
@testable import TalkCore

/// A scriptable ``HTTPTransport`` so every layer above the socket is testable offline.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [HTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replies to every request with the same JSON body.
    convenience init(json: String, status: Int = 200, headers: HTTPHeaders = .init()) {
        self.init { _ in
            HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
        }
    }

    /// Replies in order; the last response repeats if the caller keeps going.
    convenience init(sequence: [HTTPResponse]) {
        let box = Box(sequence)
        self.init { _ in box.next() }
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var lastRequest: HTTPRequest? { lock.withLock { recorded.last } }
    var requestCount: Int { lock.withLock { recorded.count } }

    func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        do {
            return try handler(request)
        } catch let error as TalkError {
            throw error
        } catch {
            throw .transport(code: -1, description: "\(error)")
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [HTTPResponse]
        private var index = 0

        init(_ responses: [HTTPResponse]) { self.responses = responses }

        func next() -> HTTPResponse {
            lock.withLock {
                defer { index = min(index + 1, responses.count - 1) }
                return responses[min(index, responses.count - 1)]
            }
        }
    }
}

extension HTTPResponse {
    static func json(_ body: String, status: Int = 200, headers: HTTPHeaders = .init()) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    static func status(_ status: Int, headers: HTTPHeaders = .init()) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data())
    }
}

/// Wraps a body in the OCS v2 envelope, the way a real server would.
func ocsEnvelope(_ data: String, statuscode: Int = 200, message: String = "OK") -> String {
    """
    {"ocs":{"meta":{"status":"ok","statuscode":\(statuscode),"message":"\(message)","totalitems":"","itemsperpage":""},"data":\(data)}}
    """
}

enum Fixture {
    /// Loads a sanitized response captured from a real Nextcloud, from `Tests/…/Fixtures`.
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    enum FixtureError: Error { case missing(String) }
}
