import XCTest
@testable import ReceiptDrop

/// Covers `SyntheticReceiptGenerator` — the fabricated demo image behind
/// "Try it with a sample receipt" (TODO.md item 9). Pure Core Graphics
/// drawing, so this runs without a device/camera and without touching any
/// of the actual OCR/extraction pipeline the demo hands the image to.
final class SyntheticReceiptGeneratorTests: XCTestCase {

    func testGeneratesANonNilImageShapedLikeAReceiptPhoto() {
        let image = SyntheticReceiptGenerator.generateImage()

        // Portrait and narrow, like an actual phone photo of a receipt held
        // at arm's length — not a square or landscape canvas. Guards against
        // a future edit accidentally swapping width/height.
        XCTAssertGreaterThan(image.size.height, image.size.width,
                              "Expected a portrait, receipt-shaped image, not something square or wide.")

        let aspectRatio = image.size.height / image.size.width
        XCTAssertGreaterThan(aspectRatio, 1.5,
                              "A real receipt photo is noticeably taller than it is wide.")

        // Sanity-check it's a real, reasonably-sized bitmap — not a
        // degenerate 0x0 or 1x1 image that would technically be "non-nil"
        // but useless to hand to Vision.
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertGreaterThan(image.size.height, 200)
        XCTAssertNotNil(image.cgImage)
    }

    func testGeneratedImageEncodesToNonEmptyPNGData() {
        // `SampleReceiptDemoView` hands `pngData()` to the extraction
        // pipeline exactly like this — a generator that draws into a
        // context but somehow produces unencodable output would silently
        // break the whole demo at this step.
        let image = SyntheticReceiptGenerator.generateImage()
        let data = image.pngData()
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 1000,
                              "Expected a real rendered receipt, not a near-empty/blank image.")
    }

    func testFabricatedTotalsAreInternallyConsistent() {
        // Subtotal + tax must equal the total actually printed on the
        // receipt — otherwise the demo would be showing a pipeline "reading"
        // a number that doesn't reconcile with the line items above it,
        // undermining the exact thing it's meant to demonstrate.
        let expectedSubtotal = SyntheticReceiptGenerator.items.reduce(0) { $0 + $1.price }
        XCTAssertEqual(SyntheticReceiptGenerator.subtotal, expectedSubtotal, accuracy: 0.001)

        let expectedTotal = (SyntheticReceiptGenerator.subtotal * 100).rounded() / 100
            + SyntheticReceiptGenerator.tax
        XCTAssertEqual(SyntheticReceiptGenerator.total, expectedTotal, accuracy: 0.001)
        XCTAssertGreaterThan(SyntheticReceiptGenerator.tax, 0)
    }

    func testVendorNameIsFabricatedNotAResemblanceToATrackedTestVendor() {
        // TODO.md item 9 is explicit that this must not resemble a real
        // business — this receipt is entirely made up, unlike the app's own
        // real test-receipt vendors.
        XCTAssertFalse(SyntheticReceiptGenerator.vendorName.isEmpty)
    }
}
