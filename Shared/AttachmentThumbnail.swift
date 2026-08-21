import ImageIO
import UIKit

/// Builds the small preview image shown next to an attachment (~220pt views,
/// up to 3x scale) without paying the cost of decoding a receipt photo at
/// its full camera resolution (commonly 4032×3024, ~12MP) just to shrink it
/// back down afterward. `CGImageSourceCreateThumbnailAtIndex` with
/// `kCGImageSourceCreateThumbnailFromImageAlways` asks ImageIO to decode
/// straight to the target size internally, which is both faster and far
/// lighter on memory than `UIImage(data:)` followed by a resize.
///
/// This only affects the *thumbnail* — callers still keep the original,
/// full-quality `Data` around (in `SharedAttachment.data`) for OCR,
/// extraction, and the zoomable photo viewer, none of which should ever see
/// a downsampled copy.
enum AttachmentThumbnail {
    /// Comfortably larger than any thumbnail view in the app renders at, so
    /// there's no visible quality loss, while still being a small fraction
    /// of a full 12MP decode.
    static let defaultMaxPixelSize: CGFloat = 800

    static func downsampled(from data: Data, maxPixelSize: CGFloat = defaultMaxPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // `kCGImageSourceCreateThumbnailFromImageAlways` scales *to* the
        // requested size — including scaling a small image *up* — which
        // isn't what "downsample" should mean. Read the real dimensions
        // first (cheap: just the header, no pixel decode) and cap the
        // request so a source already smaller than `maxPixelSize` comes
        // back unchanged instead of blown up.
        // Bridging a CFDictionary to Swift needs `String` keys, not
        // `CFString` — the latter silently fails the cast and every lookup
        // below returns nil, which is how this quietly never capped
        // anything on the first pass at this fix.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? Double(maxPixelSize)
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? Double(maxPixelSize)
        let targetPixelSize = min(maxPixelSize, CGFloat(max(pixelWidth, pixelHeight)))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
            // Bakes in EXIF orientation so the thumbnail isn't sideways —
            // `UIImage(data:)` does this implicitly, ImageIO doesn't unless asked.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgThumbnail)
    }
}
