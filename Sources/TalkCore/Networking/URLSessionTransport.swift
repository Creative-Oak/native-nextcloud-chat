import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production ``HTTPTransport``.
///
/// Holds three sessions, which differ only in their timeouts: ordinary requests, long
/// polls (which legitimately sit idle for up to a minute), and file transfers (which
/// legitimately run for minutes). Every one of them is driven through ``TransportDelegate``,
/// so the redirect rule and the response ceiling apply to every byte the app sends or
/// receives, uploads included.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let standard: PolicedSession
    private let longPoll: PolicedSession
    private let transfer: PolicedSession

    /// Requests above this asked-for timeout are long polls; above ``transferThreshold``
    /// they are file transfers. Nothing else distinguishes them at this layer.
    private static let longPollThreshold: TimeInterval = 45
    private static let transferThreshold: TimeInterval = 120

    init(userAgent: String) {
        // `timeoutIntervalForResource` is a session-wide ceiling that silently overrides
        // whatever the caller asked for, so each session's ceiling sits above every request
        // timeout that can be routed to it. A 600-second upload used to land on a session
        // whose ceiling was 180 and die after three minutes regardless.
        standard = PolicedSession(userAgent: userAgent, request: 30, resource: 120)
        longPoll = PolicedSession(userAgent: userAgent, request: 90, resource: 300)
        transfer = PolicedSession(userAgent: userAgent, request: 600, resource: 1800)
    }

    func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse {
        try await perform(request, progress: nil)
    }

    /// Uploads with byte-level progress.
    ///
    /// `didSendBodyData` on the session delegate is the only way `URLSession` reports
    /// upload progress, and it arrives for an ordinary `uploadTask` on both platforms —
    /// which is why this is the same code path as ``send(_:)`` rather than a Darwin-only
    /// special case.
    func upload(
        _ request: HTTPRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> HTTPResponse {
        try await perform(request, progress: progress)
    }

    private func policedSession(for request: HTTPRequest) -> PolicedSession {
        if request.timeout > Self.transferThreshold { return transfer }
        if request.timeout > Self.longPollThreshold { return longPoll }
        return standard
    }

    private func perform(
        _ request: HTTPRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(TalkError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers.all {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let policed = policedSession(for: request)
        let body = request.body
        let wantsProgress = progress != nil && body != nil
        if !wantsProgress { urlRequest.httpBody = body }

        let outgoing = urlRequest
        let limit = request.maximumResponseSize
        let handle = TaskHandle()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                    let task: URLSessionTask
                    if wantsProgress, let body {
                        task = policed.session.uploadTask(with: outgoing, from: body)
                    } else {
                        task = policed.session.dataTask(with: outgoing)
                    }
                    policed.delegate.register(
                        task,
                        limit: limit,
                        progress: progress,
                        continuation: continuation
                    )
                    task.resume()
                    // Cancellation that arrived while the task was being built still has to
                    // stop it. Either way the task is running, so `didCompleteWithError`
                    // is what resumes the continuation — exactly once.
                    if !handle.adopt(task) { task.cancel() }
                }
            } onCancel: {
                handle.cancel()
            }
        } catch let error as TalkError {
            throw error
        } catch {
            throw Self.map(error, host: request.url.host() ?? "")
        }
    }

    private static func map(_ error: any Error, host: String) -> TalkError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transport(code: nsError.code, description: nsError.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
            return .transport(code: nsError.code, description: "Couldn’t reach \(host).")
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return .untrustedCertificate(host: host)
        default:
            return .transport(code: nsError.code, description: nsError.localizedDescription)
        }
    }
}

// MARK: - Redirects

/// Whether a redirect may be followed.
///
/// Every request this client makes goes to the user's own Nextcloud, so there is no
/// legitimate 3xx that changes origin — and following one would re-send
/// `Authorization: Basic <app password>` and, on a 307/308, the whole request body
/// (including a file upload) to whatever host wrote the `Location`. An open redirect in any
/// app on the Nextcloud host is enough to trigger it.
///
/// Refusing outright rather than following with the header stripped is the stronger choice
/// here for a second reason: the layer above parses the response as if it came from the
/// user's server, so whoever chooses the destination would otherwise choose the
/// conversation list and the message bodies too.
enum RedirectPolicy {
    /// Same scheme, same host, same port as the request originally went to. Comparing
    /// against the *original* request rather than the current one means a chain of
    /// redirects cannot walk off the origin one hop at a time, and an `https`→`http`
    /// downgrade fails the scheme test.
    static func isSameOrigin(_ origin: URL?, _ destination: URL?) -> Bool {
        guard let origin, let destination,
              let originScheme = origin.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              originScheme == destinationScheme,
              let originHost = origin.host()?.lowercased(),
              let destinationHost = destination.host()?.lowercased(),
              originHost == destinationHost,
              port(of: origin, scheme: originScheme) == port(of: destination, scheme: destinationScheme)
        else { return false }
        return true
    }

    /// An absent port means the scheme's default, so `https://host` and `https://host:443`
    /// are one origin while `https://host:8443` is another.
    private static func port(of url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Counts a response body against the ceiling its request asked for.
///
/// Separate from the delegate so the rule itself is testable: the delegate only ever runs
/// with a live `URLSession` behind it.
struct ResponseBudget {
    let limit: Int
    private(set) var body = Data()

    init(limit: Int) {
        self.limit = limit
    }

    /// Whether an advertised `Content-Length` fits, checked before a byte is read. `-1` is
    /// what a chunked response declares, and it always "fits" — which is exactly why
    /// ``accept(_:)`` has to do the real work.
    func permits(declaredLength: Int64) -> Bool {
        declaredLength <= Int64(limit)
    }

    /// Takes a chunk. `false` means the ceiling is passed and everything accumulated so far
    /// has been dropped: keeping it would be the memory exhaustion this exists to prevent.
    mutating func accept(_ chunk: Data) -> Bool {
        guard body.count + chunk.count <= limit else {
            body = Data()
            return false
        }
        body.append(chunk)
        return true
    }
}

// MARK: - Plumbing

/// A session and the delegate that polices it.
///
/// `URLSession(configuration:delegate:delegateQueue:)` retains its delegate until the
/// session is invalidated, which is why the delegate holds no reference back to the session
/// or to the transport: there is nothing here to form a cycle with.
private struct PolicedSession: @unchecked Sendable {
    let session: URLSession
    let delegate: TransportDelegate

    init(userAgent: String, request: TimeInterval, resource: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Credentials go in the Authorization header we build ourselves; never cache them.
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegate = TransportDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

/// Runs every task on one session: refuses off-origin redirects, enforces the response
/// ceiling as the bytes land, reports upload progress, and resumes the caller.
///
/// One delegate per session, keyed by `taskIdentifier`, which is unique within a session.
private final class TransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// One in-flight request. A reference type so the callbacks can amend it in place.
    private final class Pending {
        var budget: ResponseBudget
        let progress: (@Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<HTTPResponse, any Error>?
        var response: HTTPURLResponse?
        var failure: TalkError?

        init(
            limit: Int,
            progress: (@Sendable (Double) -> Void)?,
            continuation: CheckedContinuation<HTTPResponse, any Error>
        ) {
            self.budget = ResponseBudget(limit: limit)
            self.progress = progress
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(
        _ task: URLSessionTask,
        limit: Int,
        progress: (@Sendable (Double) -> Void)?,
        continuation: CheckedContinuation<HTTPResponse, any Error>
    ) {
        lock.withLock {
            pending[task.taskIdentifier] = Pending(limit: limit, progress: progress, continuation: continuation)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let origin = task.originalRequest?.url
        guard RedirectPolicy.isSameOrigin(origin, request.url) else {
            // Named after the server the user chose, never after the host in the `Location`:
            // that string is the attacker's, and this one ends up on screen.
            let host = origin?.host() ?? ""
            lock.withLock { pending[task.taskIdentifier]?.failure = .redirectRefused(host: host) }
            Log.api.error("Refused a redirect that would have left the server's own origin")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let isOverLimit = lock.withLock { () -> Bool in
            guard let entry = pending[dataTask.taskIdentifier] else { return false }
            entry.response = response as? HTTPURLResponse
            guard !entry.budget.permits(declaredLength: response.expectedContentLength) else { return false }
            entry.failure = .responseTooLarge
            return true
        }
        completionHandler(isOverLimit ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isOverLimit = lock.withLock { () -> Bool in
            guard let entry = pending[dataTask.taskIdentifier], entry.failure == nil else { return false }
            // A chunked response declares nothing, so the count that decides this is the one
            // taken here, as the bytes land.
            guard !entry.budget.accept(data) else { return false }
            entry.failure = .responseTooLarge
            return true
        }
        if isOverLimit { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = lock.withLock { pending[task.taskIdentifier]?.progress }
        progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Taken out of the table under the lock, so from here on this entry is ours alone
        // and the continuation is resumed exactly once.
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }),
              let continuation = entry.continuation
        else { return }
        entry.continuation = nil

        if let failure = entry.failure {
            continuation.resume(throwing: failure)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let http = entry.response {
            var headers = HTTPHeaders()
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            entry.progress?(1)
            continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: entry.budget.body))
        } else {
            continuation.resume(throwing: TalkError.unexpectedResponse("Non-HTTP response"))
        }
    }
}

/// Bridges Swift task cancellation onto the `URLSessionTask` doing the work.
///
/// Without it, cancelling a chat switch would leave the long poll running to its timeout,
/// because a continuation-based request has no cancellation of its own.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// - Returns: whether the task may keep running. `false` means cancellation arrived first.
    func adopt(_ task: URLSessionTask) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            self.task = task
            return true
        }
    }

    func cancel() {
        let task: URLSessionTask? = lock.withLock {
            isCancelled = true
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}
