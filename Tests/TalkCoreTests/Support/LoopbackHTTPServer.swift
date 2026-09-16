import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A real HTTP server on 127.0.0.1, just capable enough to take a PUT and answer 201.
///
/// For the tests that need `URLSession` itself in the loop — the stub transport never reads a
/// body, so it cannot show what a stuck body does to the requests beside it. One thread per
/// connection; a connection whose body never arrives simply waits until the client gives up.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var bodies: [String: Data] = [:]

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)

        Thread { [weak self] in
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                Thread { self?.serve(connection) }.start()
            }
        }.start()
    }

    deinit { close(listener) }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func body(at path: String) -> Data? { lock.withLock { bodies[path] } }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        func readMore() -> Bool {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return false }
            received.append(contentsOf: buffer[0..<count])
            return true
        }

        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard readMore() else { return }
            headerEnd = received.range(of: separator)
        }
        let head = String(decoding: received[..<headerEnd!.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let length = lines.lazy
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0

        let bodyStart = headerEnd!.upperBound
        while received.count - bodyStart < length {
            guard readMore() else { return }
        }
        lock.withLock { bodies[path] = Data(received[bodyStart..<(bodyStart + length)]) }

        let response = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = response.withCString { send(connection, $0, strlen($0), 0) }
    }
}
