import CoreImage
import Foundation
import ImageIO
import ReplayKit

/// The screen, from the system, to kvidr's call.
///
/// The system runs this extension when kvidr is picked in the Screen Broadcast sheet, and
/// hands it every frame of the screen. Each one — at most fifteen a second, the long side at
/// most 1600 pixels, turned upright — goes to the app as a JPEG over the Unix socket the app
/// is listening on in the App Group's container: a big-endian `UInt32` length, then the bytes.
/// See `ScreenShare` in the app for the other end.
///
/// An extension has about 50 MB to live in, so a frame that arrives while the last one is
/// still being written is dropped rather than queued.
final class SampleHandler: RPBroadcastSampleHandler {
    private static let appGroup = "group.app.kvidr.ios"
    private static let maximumSide: CGFloat = 1600
    private static let frameInterval: CFTimeInterval = 1.0 / 15

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "app.kvidr.broadcast.frames")
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var isSending = false
    private var lastFrame: CFTimeInterval = 0
    private var hangUpWatch: DispatchSourceRead?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard connect() else {
            finish("Start sharing your screen from a call in kvidr.")
            return
        }
    }

    override func broadcastFinished() {
        disconnect()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        let ready = lock.withLock { () -> Bool in
            guard socket >= 0, !isSending, now - lastFrame >= Self.frameInterval else { return false }
            isSending = true
            lastFrame = now
            return true
        }
        guard ready else { return }

        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let longest = max(image.extent.width, image.extent.height)
        if longest > Self.maximumSide {
            let scale = Self.maximumSide / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
        )

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.isSending = false } }
            guard let jpeg else { return }
            if !self.send(jpeg) {
                self.finish("kvidr stopped sharing your screen.")
            }
        }
    }

    // MARK: - The socket

    private func connect() -> Bool {
        guard let path = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appending(path: "screen.sock").path(percentEncoded: false)
        else { return false }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return false
        }
        lock.withLock { socket = fd }

        // The app hanging up — the call ended, or Stop Sharing in kvidr — is the socket
        // becoming readable with nothing to read.
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        watch.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK) <= 0 {
                self?.finish("You stopped sharing your screen in kvidr.")
            }
        }
        watch.resume()
        hangUpWatch = watch
        return true
    }

    private func send(_ jpeg: Data) -> Bool {
        let fd = lock.withLock { socket }
        guard fd >= 0 else { return false }
        var length = UInt32(jpeg.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        return write(header, to: fd) && write(jpeg, to: fd)
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    private func disconnect() {
        hangUpWatch?.cancel()
        hangUpWatch = nil
        lock.withLock {
            if socket >= 0 { close(socket) }
            socket = -1
        }
    }

    private func finish(_ message: String) {
        disconnect()
        finishBroadcastWithError(NSError(
            domain: "app.kvidr.broadcast",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
