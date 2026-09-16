import CoreGraphics
import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

/// How big a shared picture is drawn in the transcript — decided before it has arrived, and
/// not changed by its arrival unless it has to be.
///
/// The transcript is pinned to its bottom edge, so a row that changes height moves every
/// message above it. The placeholder therefore takes the size the picture will have, from
/// the dimensions the server sends with the message, and keeps it: the picture is drawn into
/// that frame. The picture's own shape wins only when it disagrees with the server's — a
/// photo whose camera rotated it is the usual case — because cropping a portrait into a
/// landscape box is worse than moving once.
enum ImageLayout {
    struct Limits: Sendable {
        var maximumWidth: CGFloat
        var maximumHeight: CGFloat

        /// A picture should read as a message, not as the window; a tall panorama should
        /// not become a column to scroll past.
        static let transcript = Limits(maximumWidth: 420, maximumHeight: 520)
    }

    /// For when there is nothing to go on: the server sent no dimensions and the picture
    /// hasn't arrived.
    static let unknownSize = CGSize(width: 240, height: 180)

    /// Scaled down to fit, never up: a small picture blown out to the full width is worse
    /// than a small picture.
    static func fitted(_ size: CGSize, in limits: Limits) -> CGSize {
        guard size.width > 0, size.height > 0 else { return unknownSize }
        let scale = min(limits.maximumWidth / size.width, limits.maximumHeight / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// The frame to draw in.
    ///
    /// - Parameters:
    ///   - announced: width and height from the message, if it had them.
    ///   - original: the picture's own pixel size once it has arrived, upright.
    ///   - remembered: the size it was drawn at before, for a message without dimensions.
    static func frame(announced: CGSize?, original: CGSize?, remembered: CGSize? = nil, limits: Limits = .transcript) -> CGSize {
        if let announced, announced.width > 0, announced.height > 0 {
            guard let original, original.width > 0, original.height > 0,
                  !sameShape(announced, original)
            else { return fitted(announced, in: limits) }
            return fitted(original, in: limits)
        }
        if let original, original.width > 0, original.height > 0 { return fitted(original, in: limits) }
        if let remembered { return remembered }
        return unknownSize
    }

    /// Within a few percent. A preview is scaled from the original and rounded to whole
    /// pixels, so the ratios never match exactly.
    static func sameShape(_ a: CGSize, _ b: CGSize) -> Bool {
        let ratioA = a.width / a.height
        let ratioB = b.width / b.height
        return abs(ratioA - ratioB) / max(ratioA, ratioB) < 0.04
    }

    #if canImport(ImageIO)
    /// An image's size in pixels, turned upright — not `NSImage.size`, which is in points and
    /// halves for a picture that says it is 144 dpi.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5 to 8 turn the picture on its side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
    #endif
}
