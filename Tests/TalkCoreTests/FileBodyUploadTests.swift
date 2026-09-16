import Foundation
import Testing
@testable import TalkCore

#if canImport(Darwin)
import Darwin
#endif

/// What an attachment's bytes go through on the way out, with a real `URLSession` and a real
/// socket — the part the stub transport cannot show.
@Suite("Streaming an attachment from disk")
struct FileBodyUploadTests {
    private func scratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func put(_ file: URL, to url: URL, byteCount: Int) -> HTTPRequest {
        var request = HTTPRequest(
            method: .put,
            url: url,
            headers: ["Content-Length": String(byteCount)],
            timeout: 600
        )
        request.bodyFile = file
        return request
    }

    @Test("A file arrives whole, byte for byte")
    func streamsWholeFile() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Several chunks and several stream buffers' worth, so the pump has to wait for
        // `URLSession` to drain it more than once.
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let file = root.appendingPathComponent("big.bin")
        try bytes.write(to: file)

        let server = try LoopbackHTTPServer()
        let transport = URLSessionTransport(userAgent: "kvidr-tests")
        let progress = Tally()
        let response = try await transport.upload(put(file, to: server.url("/big"), byteCount: bytes.count)) { _ in
            progress.add()
        }

        #expect(response.status == 201)
        #expect(server.body(at: "/big") == bytes)
        #expect(progress.value > 0)
    }

    @Test("A file that never answers fails on its own and holds up nothing else")
    func stuckFileIsIsolated() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A named pipe nobody writes to: opening it for reading blocks until a writer comes,
        // which is as close as a test gets to a share whose server has gone. `URLSession`
        // would have taken it for an empty file; the pump reads it, and so it waits.
        let stuck = root.appendingPathComponent("stuck.bin")
        try #require(mkfifo(stuck.path, 0o600) == 0)
        defer {
            // Let the abandoned reader go, so the test leaves no thread behind.
            DispatchQueue.global().async {
                let writer = open(stuck.path, O_WRONLY)
                if writer >= 0 { close(writer) }
            }
        }
        let local = root.appendingPathComponent("local.txt")
        try Data("hello".utf8).write(to: local)

        let server = try LoopbackHTTPServer()
        let transport = URLSessionTransport(userAgent: "kvidr-tests", fileReadStallLimit: 0.5)
        let started = ContinuousClock.now

        let stuckFinished = Tally()
        let request = put(stuck, to: server.url("/stuck"), byteCount: 1024)
        let stuckUpload = Task { () -> TalkError? in
            defer { stuckFinished.add() }
            do {
                _ = try await transport.upload(request) { _ in }
                return nil
            } catch let error as TalkError {
                return error
            } catch {
                return nil
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        // While that one is stuck, an ordinary upload on the same transport goes straight through.
        let response = try await transport.upload(put(local, to: server.url("/local"), byteCount: 5)) { _ in }
        #expect(response.status == 201)
        #expect(server.body(at: "/local") == Data("hello".utf8))
        #expect(stuckFinished.value == 0, "went through while the stuck one was still waiting")

        // And the stuck one ends by itself, with a reason the user can act on.
        let failure = await stuckUpload.value
        #expect(failure == TalkError.fileNotAnswering)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("A file that stops answering partway through is given up on too")
    func stallsMidFile() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // The shape a share that dies mid-upload has: some of the file arrives, then a read
        // that never returns. The writer sends a megabyte and then holds the pipe open.
        let stuck = root.appendingPathComponent("stuck.bin")
        try #require(mkfifo(stuck.path, 0o600) == 0)
        let writer = Tally()
        Thread {
            let fd = open(stuck.path, O_WRONLY)
            let megabyte = [UInt8](repeating: 7, count: 1 << 20)
            _ = megabyte.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            writer.hold(fd)
        }.start()
        defer { writer.release() }

        let server = try LoopbackHTTPServer()
        let transport = URLSessionTransport(userAgent: "kvidr-tests", fileReadStallLimit: 0.5)
        let started = ContinuousClock.now
        let sent = Tally()

        await #expect(throws: TalkError.fileNotAnswering) {
            _ = try await transport.upload(put(stuck, to: server.url("/stuck"), byteCount: 300 << 20)) { _ in
                sent.add()
            }
        }
        #expect(sent.value > 0, "some of the file went out before it stopped")
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var descriptor: Int32 = -1
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
    /// Keeps a pipe's write end open until ``release()``.
    func hold(_ fd: Int32) { lock.withLock { descriptor = fd } }
    func release() {
        let fd = lock.withLock { () -> Int32 in defer { descriptor = -1 }; return descriptor }
        if fd >= 0 { close(fd) }
    }
}
