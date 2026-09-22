import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
@preconcurrency import WebRTC

/// This Mac's screen, or one window of it, going into a call. What to share is chosen in the
/// system's own picker — the same one every Mac app uses — and the frames go into a WebRTC
/// video source as they come. A whole display goes out without kvidr's own windows; see
/// ``withoutKvidr(_:)``.
@MainActor
final class ScreenShare: NSObject {
    /// Sharing began: the source is being fed.
    var onStart: () -> Void = {}
    /// Sharing ended — stopped here, from the system's own sharing menu, or the window went.
    var onStop: () -> Void = {}

    private let source: RTCVideoSource
    private let feeder: FrameFeeder
    private var stream: SCStream?
    private var isPicking = false

    init(source: RTCVideoSource) {
        self.source = source
        self.feeder = FrameFeeder(source: source)
        super.init()
    }

    /// Opens the system picker; sharing starts once something is chosen.
    func pick() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        // kvidr's own windows would only show the call showing itself.
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        isPicking = true
        picker.present()
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        finishPicking()
        Task { try? await stream?.stopCapture() }
    }

    private func finishPicking() {
        guard isPicking else { return }
        isPicking = false
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    /// A whole display, chosen in the picker, is captured without kvidr's own windows — the
    /// small call that floats while sharing above all. That takes the Screen Recording
    /// permission, which the picker alone doesn't need: asked for the first time, and until it's
    /// granted the display goes out as the picker gave it.
    private static func withoutKvidr(_ filter: SCContentFilter) async -> SCContentFilter {
        guard filter.style == .display, let chosen = filter.includedDisplays.first else { return filter }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            Log.sync.notice("Call: sharing a display without the Screen Recording permission — kvidr's own windows may show")
            return filter
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == chosen.displayID }) else { return filter }
            let kvidr = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return SCContentFilter(display: display, excludingApplications: kvidr, exceptingWindows: [])
        } catch {
            Log.sync.warning("Call: couldn’t leave kvidr out of the shared display — \(error.localizedDescription)")
            return filter
        }
    }

    private func start(with picked: SCContentFilter) async {
        let filter = await Self.withoutKvidr(picked)
        let configuration = SCStreamConfiguration()
        // Sharp enough to read, light enough for the media server: at most 1920 wide, 15 frames
        // a second — a screen changes in steps, not continuously like a face.
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        let width = min(rect.width * scale, 1920)
        let height = rect.width > 0 ? width * rect.height / rect.width : rect.height * scale
        configuration.width = max(2, Int(width) & ~1)
        configuration.height = max(2, Int(height) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.showsCursor = true
        configuration.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(feeder, type: .screen, sampleHandlerQueue: feeder.queue)
            try await stream.startCapture()
            self.stream = stream
            onStart()
        } catch {
            Log.sync.warning("Call: screen capture didn’t start — \(error.localizedDescription)")
            finishPicking()
            onStop()
        }
    }
}

extension ScreenShare: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // Handed over once, from the picker to the stream; nothing else holds on to it.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in
            if let current = self.stream {
                // Something else chosen from the system's menu while sharing: switch to it.
                try? await current.updateContentFilter(await Self.withoutKvidr(filter))
            } else {
                await self.start(with: filter)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.stream == nil else { return }
            self.finishPicking()
            self.onStop()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            Log.sync.warning("Call: the screen picker failed — \(message)")
            self.finishPicking()
            self.onStop()
        }
    }
}

extension ScreenShare: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.stream = nil
            self.finishPicking()
            self.onStop()
        }
    }
}

/// Hands each finished frame to WebRTC, off the main thread.
private final class FrameFeeder: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kvidr.screen-frames")
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer

    init(source: RTCVideoSource) {
        self.source = source
        self.capturer = RTCVideoCapturer(delegate: source)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let nanoseconds = Int64(CMTimeGetSeconds(time) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: nanoseconds)
        source.capturer(capturer, didCapture: frame)
    }
}
