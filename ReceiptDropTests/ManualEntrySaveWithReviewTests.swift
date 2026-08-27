import XCTest
@testable import ReceiptDrop

/// Tests for TODO.md item 1, "Never block the save" — the manual-entry
/// (no-AI / OCR-prefill) path used to hard-block Submit whenever OCR
/// couldn't confidently fill in a vendor or amount, with no visible
/// explanation. This suite covers what replaced that:
///
/// - `ReceiptSubmitView.resolveManualVendor` — an empty vendor still saves,
///   substituted with `unknownVendorPlaceholder` and flagged for review,
///   instead of blocking.
/// - `SubmissionPipeline.saveWithoutExtraction`'s new `needsReview`/
///   `reviewReason` parameters, which `resolveManualVendor`'s result feeds
///   into.
/// - A genuinely complete manual entry still saves cleanly (`.verified`,
///   no regression from before this change).
///
/// Amount is deliberately NOT given the same "save with a placeholder"
/// treatment — see `ReceiptSubmitView.blockedSubmitReason` — since a wrong
/// or placeholder dollar figure silently sitting in a tax record is worse
/// than an obviously-fake vendor name (totals get summed; nobody re-reads
/// every line). Submit still requires a parseable amount; the fix there is
/// that the button now says why instead of just sitting disabled.
final class ManualEntrySaveWithReviewTests: XCTestCase {
    private var testCategory: String!

    override func setUpWithError() throws {
        testCategory = "TestCategory_\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        // Clean up any history entries this test created, and the spooled
        // file/folder saveWithoutExtraction wrote via the App Group
        // container — same cleanup shape LocalReceiptStoreTests uses.
        for entry in SubmissionStore.loadHistory() where entry.category == testCategory {
            SubmissionStore.removeHistory(entry)
        }
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)?
            .appendingPathComponent("Receipts", isDirectory: true)
            .appendingPathComponent(testCategory, isDirectory: true) {
            try? FileManager.default.removeItem(at: container)
        }
    }

    // MARK: - resolveManualVendor

    func testResolveManualVendorKeepsTypedVendor() {
        let result = ReceiptSubmitView.resolveManualVendor("Home Depot")
        XCTAssertEqual(result.vendor, "Home Depot")
        XCTAssertFalse(result.needsReview)
        XCTAssertEqual(result.reviewReason, "")
    }

    func testResolveManualVendorTrimsWhitespace() {
        let result = ReceiptSubmitView.resolveManualVendor("  Shell  ")
        XCTAssertEqual(result.vendor, "Shell")
        XCTAssertFalse(result.needsReview)
    }

    func testResolveManualVendorFallsBackWhenEmpty() {
        let result = ReceiptSubmitView.resolveManualVendor("")
        XCTAssertEqual(result.vendor, ReceiptSubmitView.unknownVendorPlaceholder)
        XCTAssertTrue(result.needsReview)
        XCTAssertEqual(result.reviewReason, "Vendor name missing")
    }

    func testResolveManualVendorFallsBackWhenWhitespaceOnly() {
        // OCR prefill leaving the field untouched, or a user who typed only
        // spaces and deleted them — both must resolve the same as never
        // having typed anything, not save literal whitespace as a name.
        let result = ReceiptSubmitView.resolveManualVendor("   ")
        XCTAssertEqual(result.vendor, ReceiptSubmitView.unknownVendorPlaceholder)
        XCTAssertTrue(result.needsReview)
    }

    // MARK: - SubmissionPipeline.saveWithoutExtraction

    func testSaveWithoutExtractionFlagsNeedsReviewWhenAsked() throws {
        let entry = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("fake image bytes".utf8), kind: .image, category: testCategory,
            vendor: ReceiptSubmitView.unknownVendorPlaceholder, workDate: "2026-08-18", amount: "42.10",
            comments: "", needsReview: true, reviewReason: "Vendor name missing")

        XCTAssertEqual(entry.verificationStatus, .needsReview)
        XCTAssertEqual(entry.reviewReason, "Vendor name missing")
        XCTAssertEqual(entry.vendor, ReceiptSubmitView.unknownVendorPlaceholder)
        // Never silently dropped — it must actually be findable in history,
        // same as any other saved receipt.
        XCTAssertTrue(SubmissionStore.loadHistory().contains { $0.id == entry.id })
    }

    func testSaveWithoutExtractionDefaultsToVerifiedWhenNothingFlagged() throws {
        // A genuinely complete manual entry — vendor and amount both
        // present — must still save exactly as before this change: no
        // regression in the case that isn't touched by this fix.
        let entry = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("fake image bytes".utf8), kind: .image, category: testCategory,
            vendor: "Home Depot", workDate: "2026-08-18", amount: "42.10", comments: "lumber")

        XCTAssertEqual(entry.verificationStatus, .verified)
        XCTAssertEqual(entry.reviewReason, "")
        XCTAssertEqual(entry.vendor, "Home Depot")
        XCTAssertEqual(entry.amount, "42.10")
    }
}
