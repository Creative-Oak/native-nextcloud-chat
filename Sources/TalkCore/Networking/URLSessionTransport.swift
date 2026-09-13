import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production ``HTTPTransport``.
///
/// Holds two sessions: ordinary requests, and long polls, which legitimately sit idle
/// for up to a minute and must not be killed by the standard timeout.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let longPollSession: URLSession

    init(userAgent: String) {
        session = URLSession(configuration: Self.configuration(userAgent: userAgent, request: 30, resource: 120))
        // Long polls legitimately sit idle for up to `timeout` seconds (max 60 per the
        // Talk docs), so they get their own session with headroom above that.
        longPollSession = URLSession(configuration: Self.configuration(userAgent: userAgent, request: 90, resource: 180))
    }

    private static func configuration(
        userAgent: String,
        request: TimeInterval,
        resource: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Credentials go in the Authorization header we build ourselves; never cache them.
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers.all {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let session = request.timeout > 45 ? longPollSession : session

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TalkError.unexpectedResponse("Non-HTTP response")
            }
            var headers = HTTPHeaders()
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
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
