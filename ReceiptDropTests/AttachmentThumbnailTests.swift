import XCTest
@testable import ReceiptDrop

/// Covers the pure logic in `AttachmentThumbnail.downsampled` — the fix for
/// the Retry Queue's "Continue Without AI" stall relies on this actually
/// shrinking a full-resolution image rather than just re-wrapping it, and on
/// not distorting the result.
final class AttachmentThumbnailTests: XCTestCase {

    /// Renders a solid-color JPEG of the given pixel size, standing in for
    /// a camera capture without needing a real photo fixture.
    private func makeImageData(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        // Force scale 1 — otherwise the renderer uses the simulator's
        // screen scale (commonly 3x) and the encoded JPEG ends up with
        // `width`×3 actual pixels, throwing off every assertion below that
        // expects `width`/`height` to be pixel counts.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testDownsampledShrinksALargeImageToTheRequestedMaxPixelSize() {
        // Stand-in for the ~4032×3024 captures the bug report mentions.
        let data = makeImageData(width: 4032, height: 3024)

        let thumbnail = AttachmentThumbnail.downsampled(from: data, maxPixelSize: 800)

        XCTAssertNotNil(thumbnail)
        guard let thumbnail else { return }
        let pixelWidth = thumbnail.size.width * thumbnail.scale
        let pixelHeight = thumbnail.size.height * thumbnail.scale
        XCTAssertLessThanOrEqual(pixelWidth, 800)
        XCTAssertLessThanOrEqual(pixelHeight, 800)
        // The longer side should land close to the cap, not shrink far
        // past it — otherwise the thumbnail would be needlessly blurry.
        XCTAssertGreaterThan(max(pixelWidth, pixelHeight), 700)
    }

    func testDownsampledPreservesAspectRatio() {
        let data = makeImageData(width: 4032, height: 3024) // 4:3
        guard let thumbnail = AttachmentThumbnail.downsampled(from: data, maxPixelSize: 800) else {
            return XCTFail("expected a thumbnail")
        }
        let originalRatio = 4032.0 / 3024.0
        let thumbnailRatio = Double(thumbnail.size.width / thumbnail.size.height)
        XCTAssertEqual(thumbnailRatio, originalRatio, accuracy: 0.02)
    }

    func testDownsampledLeavesASmallImageRoughlyAsIs() {
        // Already smaller than the cap — ImageIO shouldn't upscale it.
        let data = makeImageData(width: 300, height: 200)
        guard let thumbnail = AttachmentThumbnail.downsampled(from: data, maxPixelSize: 800) else {
            return XCTFail("expected a thumbnail")
        }
        XCTAssertLessThanOrEqual(thumbnail.size.width * thumbnail.scale, 300)
        XCTAssertLessThanOrEqual(thumbnail.size.height * thumbnail.scale, 200)
    }

    func testDownsampledReturnsNilForGarbageData() {
        XCTAssertNil(AttachmentThumbnail.downsampled(from: Data([0x00, 0x01, 0x02])))
    }
}
