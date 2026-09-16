import Foundation

/// Feeds a file into a request body from a thread of its own, and notices when the file
/// stops answering.
///
/// `uploadTask(with:fromFile:)` looked like the answer to a file on a wedged network share
/// and was not: `URLSession` reads the file on its own internal threads, and a read that
/// never returns there stalls every other transfer in the process — a paused SMB server
/// took a local upload in another conversation down with it. So `URLSession` is handed a
/// stream it can always read from, and the file is read into that stream here, by one
/// dedicated thread. If the share goes away, that thread is what waits.
///
/// Nothing can interrupt a read stuck in the kernel on a hard-mounted share, so a watchdog
/// times the reads instead: one that has been in progress longer than `stallLimit` fails
/// the transfer, and the thread is abandoned to finish whenever the mount lets it. Only
/// time spent *inside* `open` and `read` counts. Waiting for the network to take the bytes
/// already read is a slow connection, not a dead disk, and is left to the request timeout.
final class FileBodyPump: @unchecked Sendable {
    private let file: URL
    private let output: OutputStream
    private let stallLimit: TimeInterval
    private static let chunkSize = 64 * 1024

    private let lock = NSLock()
    /// When the read in progress began; nil between reads.
    private var readStartedAt: Date?
    private var isStopped = false
    private var onFailure: (@Sendable (TalkError) -> Void)?
    private var watchdog: (any DispatchSourceTimer)?

    /// The pump, and the stream to hand `URLSession` as the body.
    static func make(file: URL, stallLimit: TimeInterval) -> (body: InputStream, pump: FileBodyPump) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4 * chunkSize, inputStream: &input, outputStream: &output)
        // Bound streams are made in memory and cannot fail to exist; a nil here is a
        // Foundation bug, not a condition to recover from.
        let pump = FileBodyPump(file: file, output: output!, stallLimit: stallLimit)
        return (input!, pump)
    }

    private init(file: URL, output: OutputStream, stallLimit: TimeInterval) {
        self.file = file
        self.output = output
        self.stallLimit = stallLimit
    }

    /// Starts reading. `onFailure` is called at most once, from any thread: the file stopped
    /// answering, or could not be read at all. Not called after ``stop()``.
    func start(onFailure: @escaping @Sendable (TalkError) -> Void) {
        lock.withLock { self.onFailure = onFailure }

        let interval = max(0.05, min(1, stallLimit / 4))
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        lock.withLock { watchdog = timer }
        timer.resume()

        let thread = Thread { [self] in pump() }
        thread.name = "app.kvidr.file-body"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The transfer is over, however it ended. A thread still stuck in a read stays stuck
    /// until the file system lets go, and then leaves without writing anything.
    func stop() {
        let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
            isStopped = true
            onFailure = nil
            defer { watchdog = nil }
            return watchdog
        }
        timer?.cancel()
    }

    // MARK: - The reading thread

    private func pump() {
        output.open()
        defer { output.close() }

        // Opening is as much a trip to the share as reading is.
        beginRead()
        let handle = try? FileHandle(forReadingFrom: file)
        endRead()
        guard let handle else {
            return fail(FileManager.default.fileExists(atPath: file.path) ? .fileNotAttachable : .fileMissing)
        }
        defer { try? handle.close() }

        while !stopped {
            beginRead()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: Self.chunkSize)
            } catch {
                endRead()
                // A soft-mounted share gives up eventually with an I/O error, which means the
                // same thing to the person waiting as one that never answers.
                return fail(.fileNotAnswering)
            }
            endRead()
            guard let chunk, !chunk.isEmpty else { return }
            guard write(chunk) else { return }
        }
    }

    /// Hands a chunk to the stream, waiting while `URLSession` catches up. `false` means
    /// stop: the transfer ended, or the other end of the stream went away.
    private func write(_ chunk: Data) -> Bool {
        var offset = 0
        while offset < chunk.count {
            if stopped { return false }
            guard output.hasSpaceAvailable else {
                if output.streamStatus == .error || output.streamStatus == .closed { return false }
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let written = chunk.withUnsafeBytes { buffer in
                output.write(
                    buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                    maxLength: chunk.count - offset
                )
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private var stopped: Bool { lock.withLock { isStopped } }

    private func beginRead() { lock.withLock { readStartedAt = Date() } }
    private func endRead() { lock.withLock { readStartedAt = nil } }

    // MARK: - Failure

    private func checkForStall() {
        let isStalled = lock.withLock { () -> Bool in
            guard let started = readStartedAt else { return false }
            return Date().timeIntervalSince(started) > stallLimit
        }
        if isStalled { fail(.fileNotAnswering) }
    }

    private func fail(_ error: TalkError) {
        let report = lock.withLock { () -> (@Sendable (TalkError) -> Void)? in
            defer { onFailure = nil }
            return onFailure
        }
        report?(error)
    }
}
