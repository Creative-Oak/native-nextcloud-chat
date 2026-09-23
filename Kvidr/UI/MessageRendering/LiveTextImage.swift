import AppKit
import SwiftUI
import VisionKit

/// A picture whose text can be selected and copied — Live Text, as Preview and Photos have
/// it: point at a word and drag, or press the Live Text button in its corner to see what's
/// there. Phone numbers, addresses, links and codes in it work as they do there too. The
/// picture is read on this Mac, when it opens.
struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> LiveTextImageView {
        LiveTextImageView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ view: LiveTextImageView, context: Context) {
        view.show(image)
    }

    final class LiveTextImageView: NSView {
        private let imageView = NSImageView()
        private let overlay = ImageAnalysisOverlayView()
        private var analysisTask: Task<Void, Never>?
        private weak var shown: NSImage?

        init(cornerRadius: CGFloat) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            // Accessibility reads the picture's own description; the overlay adds the text.
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            overlay.trackingImageView = imageView
            overlay.preferredInteractionTypes = .automatic
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = bounds
            addSubview(overlay)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        override var intrinsicContentSize: NSSize { imageView.image?.size ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

        func show(_ image: NSImage) {
            guard image !== shown else { return }
            shown = image
            imageView.image = image
            overlay.analysis = nil
            invalidateIntrinsicContentSize()
            analysisTask?.cancel()
            guard ImageAnalyzer.isSupported else { return }
            analysisTask = Task { [weak self] in
                let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
                guard let self, !Task.isCancelled else { return }
                self.overlay.analysis = analysis
            }
        }

        deinit {
            analysisTask?.cancel()
        }
    }
}
