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

    // MARK: - SubmissionPipeline.saveWithoutExtraction allowDuplicate

    /// Default behavior (`allowDuplicate` omitted, i.e. `false`) — a second
    /// save with the same category/date/amount must still be rejected as a
    /// duplicate. This is the existing, unchanged safety net; the point of
    /// this test is to lock in that adding the bypass parameter didn't
    /// quietly loosen the default path.
    func testSaveWithoutExtractionStillRejectsDuplicateByDefault() throws {
        _ = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("first".utf8), kind: .image, category: testCategory,
            vendor: "Coffee Shop", workDate: "2026-08-18", amount: "4.50", comments: "")

        XCTAssertThrowsError(try SubmissionPipeline.saveWithoutExtraction(
            data: Data("second".utf8), kind: .image, category: testCategory,
            vendor: "A Different Coffee Shop", workDate: "2026-08-18", amount: "4.50", comments: "")
        ) { error in
            guard case SubmissionError.duplicate = error else {
                return XCTFail("expected SubmissionError.duplicate, got \(error)")
            }
        }
    }

    /// `allowDuplicate: true` is the "Save Anyway" bypass — an otherwise
    /// identical category/date/amount match must be allowed through
    /// instead of thrown, and the second entry must actually land in
    /// history as its own row rather than being silently absorbed into the
    /// first (the whole point: a repeat coffee order on the same day for
    /// the same total is a real, distinct receipt).
    func testSaveWithoutExtractionAllowDuplicateBypassesTheCheck() throws {
        let first = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("first".utf8), kind: .image, category: testCategory,
            vendor: "Coffee Shop", workDate: "2026-08-18", amount: "4.50", comments: "")

        let second = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("second".utf8), kind: .image, category: testCategory,
            vendor: "A Different Coffee Shop", workDate: "2026-08-18", amount: "4.50", comments: "",
            allowDuplicate: true)

        XCTAssertNotEqual(first.id, second.id)
        let history = SubmissionStore.loadHistory()
        XCTAssertTrue(history.contains { $0.id == first.id })
        XCTAssertTrue(history.contains { $0.id == second.id })
    }

    // MARK: - SubmissionPipeline.confirmReviewed

    /// Covers the "Confirm" swipe action / "Looks Good" button in
    /// ReceiptsView: the tester decides an already-extracted, flagged
    /// receipt was fine all along and just wants the flag gone — a pure
    /// status flip, not a field edit. Must flip status, clear the reason,
    /// and leave every other field — including the CSV Comments column,
    /// which `confirmReviewed` never touches — exactly as it was.
    func testConfirmReviewedClearsFlagAndPreservesEverythingElse() throws {
        let entry = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("fake image bytes".utf8), kind: .image, category: testCategory,
            vendor: "Ambiguous Vendor", workDate: "2026-08-18", amount: "42.10",
            comments: "some note", needsReview: true,
            reviewReason: "Ambiguous total and unclear date formatting")

        let updated = SubmissionPipeline.confirmReviewed(entry)

        XCTAssertEqual(updated.verificationStatus, .verified)
        XCTAssertEqual(updated.reviewReason, "")
        // Everything else about the entry is untouched — same id, same data.
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.vendor, entry.vendor)
        XCTAssertEqual(updated.amount, entry.amount)
        XCTAssertEqual(updated.workDate, entry.workDate)
        XCTAssertEqual(updated.category, entry.category)
        XCTAssertEqual(updated.receiptLink, entry.receiptLink)
        XCTAssertEqual(updated.vendorType, entry.vendorType)
        XCTAssertEqual(updated.extraFiles, entry.extraFiles)

        // Persisted, not just returned in memory — the App Group History
        // store must reflect the change too, or it would revert on next
        // launch (this is the same store `reload()` reads from).
        let stored = SubmissionStore.loadHistory().first { $0.id == entry.id }
        XCTAssertEqual(stored?.verificationStatus, .verified)
        XCTAssertEqual(stored?.reviewReason, "")

        // The CSV row is untouched entirely — confirmReviewed never rewrites
        // it, since verificationStatus/reviewReason aren't CSV columns.
        let comments = LocalReceiptStore.comments(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink)
        XCTAssertEqual(comments, "some note")
    }

    // MARK: - Date fallback confirmation copy + flagging

    // The prompt itself (`ReceiptSubmitView.SubmitState.confirmDate`) isn't
    // testable here, but everything it says and everything it writes into the
    // saved entry is.

    func testDateConfirmCopyDistinguishesTheThreeFailureCases() {
        // "No date is printed here" is routine; "dates are printed and I
        // couldn't read them" means the right date is probably on the paper;
        // "I couldn't read this photo at all" points at the photo, not the
        // receipt. Three different things to do about it, so three different
        // messages — the manual path can genuinely tell them apart (the AI
        // path can't, and doesn't try).
        let noDate = ReceiptSubmitView.dateConfirmTitle(for: .noDatePrinted)
        let ambiguous = ReceiptSubmitView.dateConfirmTitle(for: .ambiguous(printedDates: 2))
        let noText = ReceiptSubmitView.dateConfirmTitle(for: .noTextRecognized)
        XCTAssertNotEqual(noDate, ambiguous)
        XCTAssertNotEqual(ambiguous, noText)
        XCTAssertNotEqual(noDate, noText)
        XCTAssertEqual(ReceiptSubmitView.dateConfirmTitle(for: nil), noText)

        // Every message has to state the consequence — that's the whole
        // reason the prompt is worth interrupting a save for.
        for resolution: ManualEntryOCRPrefill.DateResolution? in
            [.noDatePrinted, .ambiguous(printedDates: 2), .noTextRecognized, nil] {
            let message = ReceiptSubmitView.dateConfirmMessage(for: resolution)
            XCTAssertTrue(message.contains("tax year"), "missing consequence: \(message)")
            XCTAssertTrue(message.contains("Today's date will be used"), "missing fallback: \(message)")
        }
        // The ambiguous message names how many dates were actually printed.
        XCTAssertTrue(ReceiptSubmitView.dateConfirmMessage(for: .ambiguous(printedDates: 3)).contains("3 dates"))
        XCTAssertTrue(ReceiptSubmitView.dateConfirmMessage(for: .ambiguous(printedDates: 1)).contains("A date is printed"))
    }

    func testConfirmedTodayReviewReasonStaysOutOfTheAIPathsPromptSuffix() {
        // `ReceiptSubmitView.finishAfterSave` and `ScannedTextSubmitView`
        // both raise their own post-save date prompt for any reason ending
        // "defaulted to today". A date the user has *already* confirmed must
        // not match that, or confirming would immediately re-prompt.
        for resolution: ManualEntryOCRPrefill.DateResolution? in
            [.noDatePrinted, .ambiguous(printedDates: 2), .noTextRecognized, nil] {
            let reason = ReceiptSubmitView.confirmedTodayReviewReason(for: resolution)
            XCTAssertFalse(reason.hasSuffix("defaulted to today"), reason)
            XCTAssertTrue(reason.contains("today's date"), reason)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testCombineReviewReasonsKeepsBothCauses() {
        // A save can be missing a vendor *and* have an unreadable date;
        // whichever came first used to win and the other vanished.
        let both = ReceiptSubmitView.combineReviewReasons(["Vendor name missing", "No date printed"])
        XCTAssertTrue(both.needsReview)
        XCTAssertTrue(both.reason.contains("Vendor name missing"))
        XCTAssertTrue(both.reason.contains("No date printed"))

        let one = ReceiptSubmitView.combineReviewReasons(["", "No date printed"])
        XCTAssertTrue(one.needsReview)
        XCTAssertEqual(one.reason, "No date printed")

        let none = ReceiptSubmitView.combineReviewReasons(["", "   "])
        XCTAssertFalse(none.needsReview)
        XCTAssertEqual(none.reason, "")
    }

    func testConfirmingTodaysDateStillSavesFlaggedForReview() throws {
        // The receipts that started this: a confirmed guess is intentional,
        // not verified — it must stay findable in the "needs review" group
        // rather than becoming indistinguishable from a date read off paper.
        let reason = ReceiptSubmitView.confirmedTodayReviewReason(for: .noDatePrinted)
        let (needsReview, combined) = ReceiptSubmitView.combineReviewReasons(["", reason])
        let entry = try SubmissionPipeline.saveWithoutExtraction(
            data: Data("fake image bytes".utf8), kind: .image, category: testCategory,
            vendor: "Corner Store", workDate: LocalReceiptStore.todayString(),
            amount: "12.5", comments: "",
            needsReview: needsReview, reviewReason: combined)
        XCTAssertEqual(entry.verificationStatus, .needsReview)
        XCTAssertEqual(entry.reviewReason, reason)
        XCTAssertEqual(entry.workDate, LocalReceiptStore.todayString())
    }
}
