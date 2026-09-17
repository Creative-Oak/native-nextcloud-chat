import Foundation

/// One open websocket. Behind a protocol so the connection logic can be tested against a
/// scripted server.
protocol WebSocketChannel: Sendable {
    func send(_ data: Data) async throws
    /// The next message, text or binary, as bytes. Throws once the socket has closed.
    func receive() async throws -> Data
    /// Answers when the other end answers a ping.
    func ping() async throws
    func close()
}

protocol WebSocketTransport: Sendable {
    func open(_ url: URL) -> any WebSocketChannel
}

enum WebSocketError: Error, Equatable {
    case closed
    case timedOut
}

/// `URLSessionWebSocketTask`, one task per channel.
struct URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func open(_ url: URL) -> any WebSocketChannel {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let task = session.webSocketTask(with: request)
        // Frames up to a megabyte: chat relays carry whole messages, nothing carries files.
        task.maximumMessageSize = 1024 * 1024
        task.resume()
        return URLSessionWebSocketChannel(task: task)
    }
}

private final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    // `URLSessionWebSocketTask` is thread-safe; the class only carries it across.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw WebSocketError.closed
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
