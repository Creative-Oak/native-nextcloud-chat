import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a picture into what the avatar endpoint stores as it is: a square PNG.
///
/// Centre-cropped to the shorter side, turned upright first — a phone photo is usually
/// stored sideways with an orientation tag, and cropping before applying it takes the middle
/// of the wrong axis — and scaled down to `side` if larger. Never scaled up.
enum SquareAvatar {
    static let side = 512

    enum Failure: Error, Equatable {
        case notAnImage
        case couldNotEncode
    }

    static func png(from data: Data, side: Int = SquareAvatar.side) throws(Failure) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw .notAnImage }

        // A thumbnail at full size is the documented way to get the orientation applied.
        let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary)
        guard let upright else { throw .notAnImage }

        let shorter = min(upright.width, upright.height)
        let crop = CGRect(
            x: (upright.width - shorter) / 2,
            y: (upright.height - shorter) / 2,
            width: shorter,
            height: shorter
        )
        guard let square = upright.cropping(to: crop) else { throw .notAnImage }

        let target = min(side, shorter)
        guard let context = CGContext(
            data: nil,
            width: target,
            height: target,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw .couldNotEncode }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { throw .couldNotEncode }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw .couldNotEncode
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw .couldNotEncode }
        return output as Data
    }
}
#endif
