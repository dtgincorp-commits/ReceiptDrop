import XCTest
@testable import ReceiptDrop

/// A receipt with no amount can be saved (never block the save) but never
/// confirmed. An empty amount is not stored as 0: 0 is a real value — a free
/// or fully refunded purchase — while empty means nobody entered one yet, and
/// a record marked checked with no amount is a gap nobody goes back to fill.
final class MissingAmountTests: XCTestCase {
    private var testCategory: String!

    override func setUpWithError() throws {
        testCategory = "TestCategory_\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        for entry in SubmissionStore.loadHistory() where entry.category == testCategory {
            SubmissionStore.removeHistory(entry)
        }
    }

    @discardableResult
    private func makeStoredEntry(amount: String, status: VerificationStatus,
                                 reason: String = "") -> HistoryEntry {
        let entry = HistoryEntry(
            category: testCategory, vendor: "Test Vendor", workDate: "2026-08-01",
            amount: amount, receiptLink: "test.jpg", timestamp: Date(),
            verificationStatus: status, reviewReason: reason)
        SubmissionStore.appendHistory(entry)
        return entry
    }

    private func reloaded(_ entry: HistoryEntry) -> HistoryEntry? {
        SubmissionStore.loadHistory().first { $0.id == entry.id }
    }

    func testHasAmountDistinguishesEmptyFromZero() {
        func entry(_ amount: String) -> HistoryEntry {
            HistoryEntry(category: "C", vendor: "V", workDate: "2026-08-01", amount: amount,
                         receiptLink: "x.jpg", timestamp: Date())
        }
        XCTAssertFalse(entry("").hasAmount)
        XCTAssertFalse(entry("   ").hasAmount)
        XCTAssertTrue(entry("0").hasAmount, "0 is an entered value, not a missing one")
        XCTAssertTrue(entry("0.00").hasAmount)
        XCTAssertTrue(entry("42.10").hasAmount)
    }

    func testAReceiptWithNoAmountCannotBeConfirmed() throws {
        let entry = makeStoredEntry(amount: "", status: .needsReview, reason: "Amount missing or unreadable")

        SubmissionPipeline.confirmReviewed(entry)

        let stored = try XCTUnwrap(reloaded(entry))
        XCTAssertEqual(stored.verificationStatus, .needsReview)
        XCTAssertEqual(stored.reviewReason, "Amount missing or unreadable",
                       "the reason must survive, so the row still says what to fix")
    }

    func testAZeroAmountCanStillBeConfirmed() throws {
        let entry = makeStoredEntry(amount: "0.00", status: .needsReview, reason: "Check this")

        SubmissionPipeline.confirmReviewed(entry)

        XCTAssertEqual(try XCTUnwrap(reloaded(entry)).verificationStatus, .verified)
    }

    func testPreviouslyConfirmedReceiptsWithNoAmountAreFlaggedAgain() throws {
        let missing = makeStoredEntry(amount: "", status: .verified)
        let zero = makeStoredEntry(amount: "0.0", status: .verified)
        let normal = makeStoredEntry(amount: "19.91", status: .verified)
        let unreviewed = makeStoredEntry(amount: "", status: .none)

        SubmissionPipeline.reflagConfirmedEntriesMissingAmount()

        let reflagged = try XCTUnwrap(reloaded(missing))
        XCTAssertEqual(reflagged.verificationStatus, .needsReview)
        XCTAssertEqual(reflagged.reviewReason, SubmissionPipeline.missingAmountReviewReason)
        XCTAssertEqual(try XCTUnwrap(reloaded(zero)).verificationStatus, .verified,
                       "an entered 0 is a real amount and stays confirmed")
        XCTAssertEqual(try XCTUnwrap(reloaded(normal)).verificationStatus, .verified)
        XCTAssertEqual(try XCTUnwrap(reloaded(unreviewed)).verificationStatus, .none,
                       "only receipts wrongly marked confirmed are touched")
    }

    func testTheReflagIsANoOpOnceDone() throws {
        let missing = makeStoredEntry(amount: "", status: .verified)
        SubmissionPipeline.reflagConfirmedEntriesMissingAmount()
        let first = try XCTUnwrap(reloaded(missing))

        SubmissionPipeline.reflagConfirmedEntriesMissingAmount()

        let second = try XCTUnwrap(reloaded(missing))
        XCTAssertEqual(second.verificationStatus, first.verificationStatus)
        XCTAssertEqual(second.reviewReason, first.reviewReason)
    }
}
