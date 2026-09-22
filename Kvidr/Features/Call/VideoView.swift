import AppKit
import SwiftUI
@preconcurrency import WebRTC

/// A WebRTC video track, filling its space the way FaceTime's tiles do: scaled until there
/// are no bars, the overflow cut off. WebRTC's own Mac view only stretches to its bounds, so
/// it sits inside a clipping view that keeps it at the video's proportions.
struct VideoView: View {
    let video: VideoTrack
    /// Your own camera, as a mirror shows you.
    var isMirrored = false
    /// All of it, with bars where it doesn't match — for a shared screen, where cutting off
    /// the edges would cut off what's being shown.
    var fits = false

    var body: some View {
        TrackView(video: video, fits: fits)
            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
    }
}

private struct TrackView: NSViewRepresentable {
    let video: VideoTrack
    let fits: Bool

    func makeNSView(context: Context) -> FillingVideoView {
        let view = FillingVideoView()
        view.fits = fits
        view.attach(video.track)
        return view
    }

    func updateNSView(_ view: FillingVideoView, context: Context) {
        view.fits = fits
        view.attach(video.track)
    }

    static func dismantleNSView(_ view: FillingVideoView, coordinator: ()) {
        view.attach(nil)
    }

    final class FillingVideoView: NSView, RTCVideoViewDelegate {
        private let renderer = RTCMTLNSVideoView(frame: .zero)
        private var track: RTCVideoTrack?
        private var videoSize = CGSize(width: 16, height: 9)
        var fits = false {
            didSet { if fits != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            renderer.delegate = self
            addSubview(renderer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        func attach(_ newTrack: RTCVideoTrack?) {
            guard newTrack !== track else { return }
            track?.remove(renderer)
            track = newTrack
            newTrack?.add(renderer)
        }

        override func layout() {
            super.layout()
            // Fill: the larger of the two scales, centred, the rest clipped.
            let widthScale = bounds.width / max(videoSize.width, 1)
            let heightScale = bounds.height / max(videoSize.height, 1)
            let scale = fits ? min(widthScale, heightScale) : max(widthScale, heightScale)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            renderer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }

        nonisolated func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            Task { @MainActor in
                guard size.width > 0, size.height > 0 else { return }
                self.videoSize = size
                self.needsLayout = true
            }
        }
    }
}
