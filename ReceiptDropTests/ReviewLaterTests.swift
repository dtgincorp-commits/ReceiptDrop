import XCTest
@testable import ReceiptDrop

/// Tests for the user-initiated "Review Later" flag — a receipt the *user*
/// sets aside to come back to, as opposed to one a guardrail flagged.
///
/// The distinction is the whole point of the suite. `.needsReview` already
/// existed and already drove the Receipts list's banner, filter chip and
/// Confirm action, so this feature adds no new status and no new surface:
/// it adds the two ways a person can put a receipt into that pile
/// deliberately (the submit form's toggle, the list's swipe action), and
/// one rule about what happens when both a guardrail and the user want to
/// flag the same receipt.
///
/// That rule — an automatic reason outranks the user's — is the part worth
/// pinning down. "Amount doesn't appear on the receipt" tells the user what
/// to fix when they come back; "You set this aside to review later" tells
/// them only that they did. Overwriting the first with the second would
/// lose the only actionable half, so `flagForReview` leaves an
/// already-flagged entry alone.
final class ReviewLaterTests: XCTestCase {
    private var testCategory: String!

    override func setUpWithError() throws {
        testCategory = "TestCategory_\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        for entry in SubmissionStore.loadHistory() where entry.category == testCategory {
            SubmissionStore.removeHistory(entry)
        }
    }

    /// Stores and returns an entry in the given state, so each test can start
    /// from a receipt that's actually in the history rather than a detached
    /// value — `flagForReview` persists through `SubmissionStore`, and a test
    /// that only checked the returned copy would pass even if it didn't.
    @discardableResult
    private func makeStoredEntry(status: VerificationStatus = .none,
                                 reason: String = "") -> HistoryEntry {
        let entry = HistoryEntry(
            category: testCategory, vendor: "Test Vendor", workDate: "2026-08-01",
            amount: "42.00", receiptLink: "test.jpg", timestamp: Date(),
            verificationStatus: status, reviewReason: reason)
        SubmissionStore.appendHistory(entry)
        return entry
    }

    private func reloaded(_ entry: HistoryEntry) -> HistoryEntry? {
        SubmissionStore.loadHistory().first { $0.id == entry.id }
    }

    // MARK: - Flagging a clean receipt

    func testFlagForReviewMovesACleanReceiptIntoTheReviewPile() throws {
        let entry = makeStoredEntry()
        XCTAssertEqual(entry.verificationStatus, .none)

        let flagged = SubmissionPipeline.flagForReview(entry)

        XCTAssertEqual(flagged.verificationStatus, .needsReview)
        XCTAssertEqual(flagged.reviewReason, userFlaggedReviewReason)
    }

    func testFlagForReviewPersistsToTheHistoryStore() throws {
        let entry = makeStoredEntry()

        SubmissionPipeline.flagForReview(entry)

        let stored = try XCTUnwrap(reloaded(entry))
        XCTAssertEqual(stored.verificationStatus, .needsReview)
        XCTAssertEqual(stored.reviewReason, userFlaggedReviewReason)
    }

    /// The Receipts list's `needsReviewEntries` filter is a plain
    /// `verificationStatus == .needsReview` test, so a user-flagged receipt
    /// reaching that state is the same thing as it appearing in the banner
    /// count and under the "Needs Review" chip.
    func testAUserFlaggedReceiptIsCountedAsNeedingReview() throws {
        let entry = makeStoredEntry()
        SubmissionPipeline.flagForReview(entry)

        let needingReview = SubmissionStore.loadHistory()
            .filter { $0.category == testCategory && $0.verificationStatus == .needsReview }

        XCTAssertEqual(needingReview.count, 1)
        XCTAssertEqual(needingReview.first?.id, entry.id)
    }

    /// A receipt the user reviewed and saved through Edit is `.verified`,
    /// not `.none` — setting that one aside again has to work too, or the
    /// swipe action would be dead on exactly the rows a user revisits most.
    func testAVerifiedReceiptCanBeSetAsideAgain() throws {
        let entry = makeStoredEntry(status: .verified)

        let flagged = SubmissionPipeline.flagForReview(entry)

        XCTAssertEqual(flagged.verificationStatus, .needsReview)
        XCTAssertEqual(flagged.reviewReason, userFlaggedReviewReason)
    }

    // MARK: - An automatic reason outranks the user's

    func testFlagForReviewKeepsAnExistingAutomaticReason() throws {
        let automatic = "Amount doesn't appear on the receipt"
        let entry = makeStoredEntry(status: .needsReview, reason: automatic)

        let flagged = SubmissionPipeline.flagForReview(entry)

        XCTAssertEqual(flagged.verificationStatus, .needsReview)
        XCTAssertEqual(flagged.reviewReason, automatic,
                       "The reason naming what to fix must survive a user flag on top of it")
    }

    func testFlagForReviewDoesNotRewriteHistoryForAnAlreadyFlaggedEntry() throws {
        let automatic = "Date is over a year old - please confirm"
        let entry = makeStoredEntry(status: .needsReview, reason: automatic)

        SubmissionPipeline.flagForReview(entry)

        let stored = try XCTUnwrap(reloaded(entry))
        XCTAssertEqual(stored.reviewReason, automatic)
    }

    /// `.needsReview` with no reason at all shouldn't stay reasonless: the
    /// guard that protects an automatic reason keys off the reason being
    /// non-empty, not off the status, so there's something to say here and
    /// the user's note is it.
    func testFlaggedWithNoReasonGetsTheUserReason() throws {
        let entry = makeStoredEntry(status: .needsReview, reason: "")

        let flagged = SubmissionPipeline.flagForReview(entry)

        XCTAssertEqual(flagged.reviewReason, userFlaggedReviewReason)
    }

    // MARK: - Round trip

    /// Confirm is the way back out, and it has to clear a user-set flag as
    /// cleanly as an automatic one — this is the "I came back to it, it's
    /// fine" path, which is the entire reason for setting a receipt aside.
    func testConfirmReviewedClearsAUserSetFlag() throws {
        let entry = makeStoredEntry()
        let flagged = SubmissionPipeline.flagForReview(entry)

        let confirmed = SubmissionPipeline.confirmReviewed(flagged)

        XCTAssertEqual(confirmed.verificationStatus, .verified)
        XCTAssertEqual(confirmed.reviewReason, "")
        let stored = try XCTUnwrap(reloaded(entry))
        XCTAssertEqual(stored.verificationStatus, .verified)
        XCTAssertEqual(stored.reviewReason, "")
    }

    // MARK: - The manual (no-AI) save path

    /// The manual path doesn't call `flagForReview`; it folds the user's
    /// flag into the reasons it already computes, so the ordering rule shows
    /// up here as "the automatic reason comes first in the joined string"
    /// rather than as a replacement.
    func testManualPathPutsTheAutomaticReasonBeforeTheUserFlag() {
        let automatic = "Vendor wasn't readable"
        let (needsReview, reason) = ReceiptSubmitView.combineReviewReasons(
            [automatic, "", userFlaggedReviewReason])

        XCTAssertTrue(needsReview)
        XCTAssertTrue(reason.hasPrefix(automatic), "Got: \(reason)")
        XCTAssertTrue(reason.contains(userFlaggedReviewReason), "Got: \(reason)")
    }

    func testManualPathWithOnlyTheUserFlagStillFlags() {
        let (needsReview, reason) = ReceiptSubmitView.combineReviewReasons(
            ["", "", userFlaggedReviewReason])

        XCTAssertTrue(needsReview)
        XCTAssertEqual(reason, userFlaggedReviewReason)
    }

    /// The toggle off, and nothing else wrong: the receipt saves clean, as
    /// it did before this feature existed.
    func testManualPathWithoutTheUserFlagIsUnchanged() {
        let (needsReview, reason) = ReceiptSubmitView.combineReviewReasons(["", "", ""])

        XCTAssertFalse(needsReview)
        XCTAssertEqual(reason, "")
    }
}
