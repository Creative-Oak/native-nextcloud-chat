#if os(iOS)
import CoreImage
import Foundation
import ReplayKit
import UIKit
@preconcurrency import WebRTC

/// This iPhone's or iPad's screen going into a call.
///
/// iOS lets an app capture the whole screen only from a broadcast upload extension — a
/// separate process the system starts when you pick kvidr in its Screen Broadcast sheet.
/// The extension (`KvidrBroadcast`) turns each frame into a small JPEG and writes it to a
/// Unix socket in the App Group's container; this end listens on that socket and hands the
/// frames to a WebRTC video source, which is what goes out to the call. The socket is the
/// whole protocol: the extension connecting is sharing starting, either side closing it is
/// sharing over.
@MainActor
final class ScreenShare: NSObject {
    /// Sharing began: the extension connected and frames are coming.
    var onStart: () -> Void = {}
    /// Sharing ended — stopped here, from Control Center or the status bar, or the
    /// extension went.
    var onStop: () -> Void = {}

    private let receiver: BroadcastReceiver

    init(source: RTCVideoSource) {
        self.receiver = BroadcastReceiver(source: source)
        super.init()
    }

    /// Starts listening, then brings up the system's broadcast sheet with kvidr chosen.
    func pick() {
        guard let path = BroadcastSocket.path else {
            Log.sync.warning("Call: no App Group container, so the screen can’t be shared")
            onStop()
            return
        }
        receiver.onConnect = { [weak self] in
            Task { @MainActor in self?.onStart() }
        }
        receiver.onDisconnect = { [weak self] in
            Task { @MainActor in self?.onStop() }
        }
        guard receiver.listen(at: path) else {
            onStop()
            return
        }
        Self.presentBroadcastPicker()
    }

    func stop() {
        receiver.onConnect = nil
        receiver.onDisconnect = nil
        receiver.close()
    }

    /// The only way into the system's broadcast sheet is its own button, inside
    /// `RPSystemBroadcastPickerView`; this presses it.
    private static func presentBroadcastPicker() {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastSocket.extensionBundleID
        picker.showsMicrophoneButton = false
        let button = picker.subviews.lazy.compactMap { $0 as? UIButton }.first
        button?.sendActions(for: .touchUpInside)
    }
}

/// The names both ends agree on.
enum BroadcastSocket {
    static let appGroup = "group.app.kvidr.ios"
    static var extensionBundleID: String {
        (Bundle.main.bundleIdentifier ?? "app.kvidr.ios") + ".broadcast"
    }

    static var path: String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "screen.sock").path(percentEncoded: false)
    }
}

/// Accepts the extension's connection and reads its frames, on a thread of its own: the
/// reads block, and a frame is decoded where it arrives.
///
/// Each frame is a big-endian `UInt32` length and that many bytes of JPEG, already upright.
private final class BroadcastReceiver: @unchecked Sendable {
    var onConnect: (@Sendable () -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    init(source: RTCVideoSource) {
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
    }

    func listen(at path: String) -> Bool {
        close()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return false
        }
        lock.withLock { listener = fd }

        let thread = Thread { [weak self] in self?.run(listener: fd) }
        thread.name = "app.kvidr.broadcast-receiver"
        thread.start()
        return true
    }

    func close() {
        lock.withLock {
            if client >= 0 { shutdown(client, SHUT_RDWR) }
            if listener >= 0 { Darwin.close(listener) }
            listener = -1
        }
    }

    private func run(listener fd: Int32) {
        let connection = accept(fd, nil, nil)
        // One connection per share; the listener's job is done either way.
        lock.withLock {
            if listener == fd { Darwin.close(fd); listener = -1 }
        }
        guard connection >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { client = connection }
        onConnect?()

        while let frame = readFrame(from: connection) {
            deliver(frame)
        }

        lock.withLock { client = -1 }
        Darwin.close(connection)
        onDisconnect?()
    }

    private func readFrame(from fd: Int32) -> Data? {
        guard let header = read(4, from: fd) else { return nil }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        // Anything past this is not a frame the extension would have made.
        guard length > 0, length < 16 * 1024 * 1024 else { return nil }
        return read(Int(length), from: fd)
    }

    private func read(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return data
    }

    private func deliver(_ jpeg: Data) {
        guard let image = CIImage(data: jpeg) else { return }
        let size = image.extent.size
        guard let buffer = pixelBuffer(size: size) else { return }
        context.render(image, to: buffer)
        let nanoseconds = Int64(CACurrentMediaTime() * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: nanoseconds)
        source.capturer(capturer, didCapture: frame)
    }

    private func pixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
#endif
