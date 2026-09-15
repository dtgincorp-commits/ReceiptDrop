import XCTest
@testable import ReceiptDrop

/// Tests for the model-agnostic extraction logic — the parts every backend
/// (Claude, OpenAI, Gemini, Apple on-device) shares. No network, no API key,
/// and no Apple Intelligence model required, so these run on any simulator or
/// device. This is the safety net that guarantees a bad read gets flagged for
/// human review no matter which engine produced it.
final class ExtractionLogicTests: XCTestCase {

    // Yesterday-ish, comfortably inside the plausible window.
    private var recentDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return f.string(from: Calendar.current.date(byAdding: .day, value: -3, to: Date())!)
    }

    // MARK: - ExtractedReceipt.build HITL flagging

    func testCleanReceiptDoesNotNeedReview() {
        let r = ExtractedReceipt.build(
            vendor: "Home Depot", rawWorkDate: recentDate, amount: "42.10",
            comments: "lumber", rawVendorType: "hardware_home_improvement",
            modelReportedLowConfidence: false, modelReason: "")
        XCTAssertFalse(r.needsReview)
        XCTAssertEqual(r.vendor, "Home Depot")
        XCTAssertEqual(r.amount, "42.10")
        XCTAssertEqual(r.vendorType, "hardware_home_improvement")
    }

    func testEmptyVendorFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "", rawWorkDate: recentDate, amount: "10.00",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.reviewReason, "Vendor name missing")
    }

    func testEmptyAmountFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "Shell", rawWorkDate: recentDate, amount: "",
            comments: "", rawVendorType: "gas_station", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.reviewReason, "Amount missing or unreadable")
    }

    func testNonNumericAmountFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "Shell", rawWorkDate: recentDate, amount: "twelve",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
    }

    func testZeroAmountFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "Shell", rawWorkDate: recentDate, amount: "0",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
    }

    func testUnparseableDateFlaggedAndDefaultedToToday() {
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: "not a date", amount: "8.00",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        // normalizeDate falls back to today for anything unparseable.
        let today = DateFormatter.posixDay.string(from: Date())
        XCTAssertEqual(r.workDate, today)
    }

    func testFutureDateFlagged() {
        let future = DateFormatter.posixDay.string(from: Calendar.current.date(byAdding: .day, value: 10, to: Date())!)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: future, amount: "8.00",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.reviewReason, "Date is in the future")
    }

    func testVeryOldDateFlagged() {
        let old = DateFormatter.posixDay.string(from: Calendar.current.date(byAdding: .month, value: -18, to: Date())!)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: old, amount: "8.00",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
    }

    func testModelReportedLowConfidenceIsHonored() {
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: recentDate, amount: "8.00",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: true, modelReason: "blurry total")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.reviewReason, "blurry total")
    }

    func testUnknownVendorTypeCoercedToEmpty() {
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: recentDate, amount: "8.00",
            comments: "", rawVendorType: "spaceship_parts",
            modelReportedLowConfidence: false, modelReason: "")
        // Never let a model's invented token corrupt the vocabulary.
        XCTAssertEqual(r.vendorType, "")
    }

    // MARK: - VendorTypeToken

    func testVendorTypeResolvesBuiltinCaseInsensitively() {
        XCTAssertEqual(VendorTypeToken.resolve("Gas_Station"), "gas_station")
        XCTAssertEqual(VendorTypeToken.resolve("  restaurant "), "restaurant")
    }

    func testVendorTypeUnknownReturnsNil() {
        XCTAssertNil(VendorTypeToken.resolve("spaceship_parts"))
        XCTAssertNil(VendorTypeToken.resolve(""))
    }

    func testAllValidValuesIncludesBuiltins() {
        XCTAssertTrue(VendorTypeToken.allValidValues.contains("restaurant"))
        XCTAssertTrue(VendorTypeToken.allValidValues.contains("other"))
    }

    // MARK: - normalizeDate

    func testNormalizeDatePassesThroughValid() {
        XCTAssertEqual(ClaudeService.normalizeDate("2026-03-14"), "2026-03-14")
    }

    func testNormalizeDateParsesReceiptFormats() {
        // The Holiday Market receipt case: "3/20/24" must become 2024-03-20,
        // not today's date.
        XCTAssertEqual(ClaudeService.normalizeDate("3/20/24"), "2024-03-20")
        XCTAssertEqual(ClaudeService.normalizeDate("03/20/2024"), "2024-03-20")
        XCTAssertEqual(ClaudeService.normalizeDate("3-20-24"), "2024-03-20")
        XCTAssertEqual(ClaudeService.normalizeDate("Mar 20, 2024"), "2024-03-20")
    }

    func testNormalizeDateHandlesLowDayNumbers() {
        // Regression: DateFormatter treats "/" and "-" as interchangeable,
        // so "yyyy-MM-dd" used to silently claim short US dates whenever the
        // day was 12 or lower (an invalid day above 12 was the only thing
        // that used to save the correct pattern's turn) — e.g. "8/8/26" was
        // read as year 8 / month 8 / day 26, promoted to 2008-08-26 instead
        // of 2026-08-08. Every case here uses a day <= 12, which the earlier
        // tests above (day 20) never exercised.
        XCTAssertEqual(ClaudeService.normalizeDate("8/8/26"), "2026-08-08")
        XCTAssertEqual(ClaudeService.normalizeDate("1/2/25"), "2025-01-02")
        XCTAssertEqual(ClaudeService.normalizeDate("08/08/26"), "2026-08-08")
        XCTAssertEqual(ClaudeService.normalizeDate("8-8-26"), "2026-08-08")
        XCTAssertEqual(ClaudeService.normalizeDate("8/8/26 2:29 PM"), "2026-08-08")
        XCTAssertEqual(ClaudeService.normalizeDate("2026-08-08"), "2026-08-08")
        XCTAssertEqual(ClaudeService.normalizeDate("2026/08/08"), "2026-08-08")
        // Day above 12 — must keep working exactly as before.
        XCTAssertEqual(ClaudeService.normalizeDate("12/25/26"), "2026-12-25")
    }

    func testNormalizeDateFallsBackToTodayForGarbage() {
        let today = DateFormatter.posixDay.string(from: Date())
        XCTAssertEqual(ClaudeService.normalizeDate("not a date"), today)
        XCTAssertEqual(ClaudeService.normalizeDate(""), today)
    }

    func testReceiptFormatDateNotFlaggedUnreadable() {
        // A valid receipt-format date should be stored correctly and NOT
        // flagged as "unreadable" (it may still be flagged "old" — that's fine).
        let r = ExtractedReceipt.build(
            vendor: "Holiday Market", rawWorkDate: "3/20/24", amount: "27.71",
            comments: "", rawVendorType: "grocery",
            modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.workDate, "2024-03-20")
        XCTAssertNotEqual(r.reviewReason, "Date unreadable, defaulted to today")
    }

    // MARK: - ReceiptDateDetector

    // The real receipt text from the Yellow Chilli bug report — printed
    // date is 8/8/26, with a separate bare "Time  2:30 PM" line that must
    // NOT be mistaken for a date on today.
    private let yellowChilliText = """
        The Yellow Chilli - Tustin
        2463 Park Avenue
        Tustin, CA 92782
        Take Out
        Check #9
        Ordered:            8/8/26 2:29 PM
        3 Pudina Seekh      $68.97
        1 Half Tray          $0.00
         Chanajor Garam Tikki $125.00
        2 Bread Basket      $33.98
        Subtotal           $227.95
        Tax                 $17.65
        Total              $245.60
        Credit Card         Keyed
        Time                2:30 PM
        Transaction Type    Sale
        """

    func testDateDetectorFindsPrintedDate() {
        let dates = ReceiptDateDetector.dates(in: yellowChilliText)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        XCTAssertTrue(dates.map { f.string(from: $0) }.contains("2026-08-08"))
    }

    func testDateDetectorIgnoresBareTimeLine() {
        // The "Time  2:30 PM" line has no date attached — must not register
        // as a date on today, or every receipt would silently look
        // "correct" no matter what date the AI reports.
        let dates = ReceiptDateDetector.dates(in: yellowChilliText)
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertFalse(dates.contains(today))
    }

    // MARK: - ExtractedReceipt.build date cross-check (sourceText)

    func testMatchingDateNotFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "The Yellow Chilli", rawWorkDate: "2026-08-08", amount: "245.60",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: yellowChilliText)
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertFalse(r.needsReview)
    }

    func testWrongDateIsCorrectedToThePrintedDate() {
        // The actual bug: model reads the receipt fine (in this test,
        // "today" stands in for whatever wrong date it substituted) but
        // reports a date that isn't on the receipt at all. With exactly one
        // date printed, the receipt's own text wins over the model.
        let today = DateFormatter.posixDay.string(from: Date())
        let r = ExtractedReceipt.build(
            vendor: "The Yellow Chilli", rawWorkDate: today, amount: "245.60",
            comments: "Ordered at 8/8/26 2:29 PM.", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: yellowChilliText)
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertTrue(r.needsReview)
        XCTAssertTrue(r.reviewReason.contains("2026-08-08"))
    }

    func testAmbiguousMultiDateReceiptFlagsWithoutGuessing() {
        let text = "Order date: 3/1/26\nDelivery date: 3/5/26\nTotal: $10.00"
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: "2026-03-10", amount: "10.00",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        // Model's date matches neither printed date — flagged, and NOT
        // silently rewritten to either one, since which is "the" date is
        // genuinely ambiguous.
        XCTAssertEqual(r.workDate, "2026-03-10")
        XCTAssertTrue(r.needsReview)
    }

    func testAmbiguousMultiDateReceiptAcceptsMatchingDate() {
        let text = "Order date: 3/1/26\nDelivery date: 3/5/26\nTotal: $10.00"
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: "2026-03-01", amount: "10.00",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        XCTAssertEqual(r.workDate, "2026-03-01")
        XCTAssertFalse(r.needsReview)
    }

    func testNoDetectableDateLeavesModelAnswerAlone() {
        // Detector finds nothing (unusual/unsupported format on this
        // "receipt") — that means "can't verify," not "the model is wrong."
        // Punishing correct reads on unusual receipts would be worse than
        // not checking at all.
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: "2026-03-01", amount: "10.00",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: "no date-shaped text here at all, just a total of $10.00")
        XCTAssertEqual(r.workDate, "2026-03-01")
        XCTAssertFalse(r.needsReview)
    }

    func testNilSourceTextBehavesLikeBeforeThisChange() {
        // Full-image extraction paths pass no sourceText — regression guard
        // that omitting it entirely is identical to today's behavior.
        let r = ExtractedReceipt.build(
            vendor: "The Yellow Chilli", rawWorkDate: recentDate, amount: "245.60",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.workDate, recentDate)
        XCTAssertFalse(r.needsReview)
    }

    // MARK: - ExtractedReceipt.build: no date printed anywhere (North Coast Brewing)

    // A real, substantial, multi-item restaurant receipt — vendor, address,
    // several line items, subtotal/tax/tip/total — with no date-like string
    // printed on it anywhere (not even one excluded as a non-transaction
    // date — there simply isn't one), standing in for the reported North
    // Coast Brewing receipt ($950.09, no date anywhere), which the model
    // filled in as 2026-08-08 anyway.
    private let noDateRestaurantText = """
        North Coast Brewing Co.
        455 N Main St
        Fort Bragg, CA 95437
        Table 12   Server: Alex
        1 IPA Pint            $8.00
        1 Burger Combo        $18.50
        1 Fish and Chips      $16.25
        2 Craft Soda          $9.00
        Subtotal             $58.75
        Tax                   $5.14
        Tip                   $11.75
        Total                $75.64
        Thank you for visiting!
        """

    func testNoDatePrintedAnywhereIsRejectedNotStored() {
        // The North Coast Brewing bug: the model reports a well-formed,
        // plausible, non-future, non-absurd date, and every existing guard
        // passes it — but the receipt has no date printed anywhere at all.
        // Only the presence cross-check catches this, and only because the
        // source text is substantial enough for its silence to mean
        // something.
        let today = DateFormatter.posixDay.string(from: Date())
        let r = ExtractedReceipt.build(
            vendor: "North Coast Brewing Co.", rawWorkDate: "2026-08-08", amount: "75.64",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: noDateRestaurantText)
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.workDate, today, "an invented date with nothing behind it must be discarded, not stored")
        XCTAssertTrue(r.reviewReason.contains("2026-08-08"), "the reason should name the date that was thrown away")
        XCTAssertTrue(r.reviewReason.contains("isn't printed anywhere"))
        XCTAssertTrue(r.reviewReason.hasSuffix("defaulted to today"),
                      "must end in the same suffix ReceiptSubmitView/ScannedTextSubmitView match on to raise the date prompt")
    }

    func testNilSourceTextKeepsModelDateWhenNoneIsPrintedAnywhere() {
        // No sourceText at all (full-image path) — nothing to judge
        // "nothing printed" against, so the model's date must be kept
        // exactly like every other cross-check in this function.
        let r = ExtractedReceipt.build(
            vendor: "North Coast Brewing Co.", rawWorkDate: "2026-08-08", amount: "75.64",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertFalse(r.needsReview)
    }

    func testEmptySourceTextKeepsModelDateWhenNoneIsPrintedAnywhere() {
        // An empty string is what a failed OCR pass / unreadable PDF page
        // actually produces (see FoundationModelsService.extract(data:kind:)
        // and its "render failed" fallback) — indistinguishable from "OCR
        // found nothing," not "this receipt has no date."
        let r = ExtractedReceipt.build(
            vendor: "North Coast Brewing Co.", rawWorkDate: "2026-08-08", amount: "75.64",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: "")
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertFalse(r.needsReview)
    }

    func testTooShortSourceTextKeepsModelDateWhenNoneIsPrintedAnywhere() {
        // Proves length is no longer the (a)-vs-(b) discriminator described
        // on `minimumSourceTextLengthForNoDateRejection` — it only exists to
        // catch `sourceText` that's essentially empty/garbage, the way a
        // failed OCR pass or render failure actually behaves (see
        // `FoundationModelsService.extract(data:kind:)`'s `""` fallback).
        // This fixture is deliberately shorter than any legible vendor name
        // or total could be — standing in for that degenerate case, not for
        // "a short receipt" — so it must fall below the floor and be left
        // alone regardless of what `ReceiptDateDetector` finds in it.
        let almostNothing = "blurry"
        XCTAssertLessThan(almostNothing.count, ExtractedReceipt.minimumSourceTextLengthForNoDateRejection)
        let r = ExtractedReceipt.build(
            vendor: "North Coast Brewing Co.", rawWorkDate: "2026-08-08", amount: "75.64",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: almostNothing)
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertFalse(r.needsReview)
    }

    func testSubstantialSourceTextWithMatchingPrintedDateIsStillKept() {
        // Existing behavior must survive: substantial text is exactly what
        // this rule inspects, so it must not regress the ordinary case
        // where the printed date actually matches the model's answer.
        let r = ExtractedReceipt.build(
            vendor: "The Yellow Chilli", rawWorkDate: "2026-08-08", amount: "245.60",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: yellowChilliText)
        XCTAssertGreaterThanOrEqual(yellowChilliText.count, ExtractedReceipt.minimumSourceTextLengthForNoDateRejection)
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertFalse(r.needsReview)
    }

    func testSubstantialSourceTextWithOneWrongPrintedDateStillAutoCorrects() {
        // Existing auto-correct behavior (exactly one printed date, model
        // disagrees) must keep winning over the new no-date rejection —
        // the two rules are mutually exclusive by construction (one only
        // fires when `printed` is empty), but this guards against a future
        // refactor blurring that line.
        let today = DateFormatter.posixDay.string(from: Date())
        let r = ExtractedReceipt.build(
            vendor: "The Yellow Chilli", rawWorkDate: today, amount: "245.60",
            comments: "Ordered at 8/8/26 2:29 PM.", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: yellowChilliText)
        XCTAssertEqual(r.workDate, "2026-08-08")
        XCTAssertTrue(r.needsReview)
        XCTAssertFalse(r.reviewReason.hasSuffix("defaulted to today"),
                       "auto-correct's reason, not the no-date rejection's, must win here")
    }

    // MARK: - ExtractedReceipt.build: excluded-non-transaction-date must not regress b711974

    // A realistic-length patient billing statement — letterhead, address,
    // phone number, patient/account block, an itemized charge table, and a
    // footer — whose only date-like text anywhere is the guarantor's DOB.
    // Deliberately much longer than the original (131-character)
    // `NonTransactionDateTests.medicalBillText` fixture: a real OCR pass
    // over an actual billing statement runs several hundred characters, and
    // this must stay long enough to clear the old, wrongly-reasoned
    // 200-character bar this rule used to have — otherwise this test would
    // pass for the wrong reason (too short to trigger the rule at all)
    // instead of the right one (the rule recognizes the excluded DOB and
    // stands down).
    private let realisticDOBOnlyMedicalBillText = """
        Newport-Huntington Medical Group
        Patient Billing Statement
        1200 Bristol Street North, Suite 100
        Newport Beach, CA 92660
        Phone: (949) 555-0142

        Patient: JANE R. DOE
        01/30/1969 • Guarantor
        Account #4471023
        Policy Group: PPO-4482

        Description                  Charge
        Office Visit - Established     $95.00
        Lab Panel - Comprehensive       $31.15

        Current Balance Due          $126.15
        Please remit payment to the address above.
        Thank you for choosing Newport-Huntington Medical Group.
        """

    // Same statement, but the excluded date-like text is a due date instead
    // of a DOB — the other confirmed label from `nonTransactionDateLabels`,
    // proving this isn't a DOB-specific fix.
    private let realisticDueDateOnlyMedicalBillText = """
        Newport-Huntington Medical Group
        Patient Billing Statement
        1200 Bristol Street North, Suite 100
        Newport Beach, CA 92660
        Phone: (949) 555-0142

        Patient: JANE R. DOE
        Account #4471023
        Policy Group: PPO-4482

        Description                  Charge
        Office Visit - Established     $95.00
        Lab Panel - Comprehensive       $31.15

        Current Balance Due          $126.15
        Due Date 09/15/2026
        Please remit payment to the address above.
        Thank you for choosing Newport-Huntington Medical Group.
        """

    func testRealisticLengthDOBOnlyMedicalBillKeepsGoodDateB711974Regression() {
        // The regression the coordinator caught: at realistic OCR length
        // (well past the old 200-character bar), `ReceiptDateDetector.dates`
        // returns empty here — not because there's no date-like text, but
        // because "01/30/1969 • Guarantor" is excluded by
        // `namesNonTransactionDate`, exactly as b711974 intended. A
        // length-only "empty means invent" rule cannot tell that apart from
        // the North Coast Brewing case and would wrongly discard a good
        // date — re-breaking b711974 one commit after it shipped. This must
        // route through `containsExcludedNonTransactionDate` and leave the
        // model's date alone.
        XCTAssertGreaterThanOrEqual(realisticDOBOnlyMedicalBillText.count, 400)
        XCTAssertTrue(ReceiptDateDetector.dates(in: realisticDOBOnlyMedicalBillText).isEmpty)
        XCTAssertTrue(ReceiptDateDetector.containsExcludedNonTransactionDate(in: realisticDOBOnlyMedicalBillText))

        let recent = DateFormatter.posixDay.string(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        let r = ExtractedReceipt.build(
            vendor: "Newport-Huntington Medical Group", rawWorkDate: recent,
            amount: "126.15", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: realisticDOBOnlyMedicalBillText)
        XCTAssertEqual(r.workDate, recent, "a correct date must not be discarded just because the only printed date is an excluded DOB")
        XCTAssertFalse(r.needsReview)
    }

    func testRealisticLengthDueDateOnlyMedicalBillKeepsGoodDate() {
        // Same shape as the DOB case above, with a due date standing in —
        // confirms the fix isn't keyed to DOB specifically but to "some
        // date-like text was excluded," whichever label caused it.
        XCTAssertGreaterThanOrEqual(realisticDueDateOnlyMedicalBillText.count, 400)
        XCTAssertTrue(ReceiptDateDetector.dates(in: realisticDueDateOnlyMedicalBillText).isEmpty)
        XCTAssertTrue(ReceiptDateDetector.containsExcludedNonTransactionDate(in: realisticDueDateOnlyMedicalBillText))

        let recent = DateFormatter.posixDay.string(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        let r = ExtractedReceipt.build(
            vendor: "Newport-Huntington Medical Group", rawWorkDate: recent,
            amount: "126.15", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: realisticDueDateOnlyMedicalBillText)
        XCTAssertEqual(r.workDate, recent, "a correct date must not be discarded just because the only printed date is an excluded due date")
        XCTAssertFalse(r.needsReview)
    }

    func testAbsurdDateWithNoSourceTextEvidenceIsNotDoubleProcessed() {
        // A date already discarded by the tier-2 absurdity rule (see
        // NonTransactionDateTests) must not also run through the new
        // no-date rejection — `dateRejected` already guards the shared
        // `if let sourceText, !dateRejected` block above both branches, so
        // this is really a regression guard on that guard: the reason must
        // appear exactly once, not doubled by two independent rules firing
        // for the same missing date.
        let today = DateFormatter.posixDay.string(from: Date())
        let r = ExtractedReceipt.build(
            vendor: "Newport-Huntington Medical Group", rawWorkDate: "1969-01-30",
            amount: "75.64", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: noDateRestaurantText)
        XCTAssertEqual(r.workDate, today)
        XCTAssertTrue(r.reviewReason.contains("years old"), "the absurdity rule's own reason must be the one that fires")
        XCTAssertFalse(r.reviewReason.contains("isn't printed anywhere"), "must not also run the no-date rule on the same discarded date")
        XCTAssertEqual(r.reviewReason.components(separatedBy: "defaulted to today").count - 1, 1,
                       "the suffix must appear exactly once, not doubled by two rules firing")
    }

    // MARK: - ReceiptAmountDetector

    // Same offset as `recentDate` (3 days ago), formatted the way this
    // receipt prints it — keeps the fixture's printed date in sync with
    // `recentDate` no matter when the suite actually runs, so the (separate,
    // already-tested) date guardrail never has a reason to fire in these
    // amount-focused tests. A literal hardcoded date here previously caused
    // exactly that: it silently drifted out of sync with `recentDate` and
    // tripped the date cross-check for reasons unrelated to what the test
    // was actually checking.
    private var naanAndKabobDateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy"
        return f.string(from: Calendar.current.date(byAdding: .day, value: -3, to: Date())!)
    }

    // The real receipt text from the Naan and Kabob bug report — a blank
    // "TOTAL AMOUNT" line (tip never filled in) with only $66.23 printed.
    // Sequence/batch/invoice numbers are included deliberately: they must
    // NOT be picked up as amounts (see ReceiptAmountDetector's "looks like
    // money" requirement).
    private var naanAndKabobText: String {
        """
        NAAN AND KABOB LLC
        416 E 1ST ST
        TUSTIN, CA 92780
        \(naanAndKabobDateString)            13:30:03
        CREDIT CARD
        VISA SALE
        Card #: XXXXXXXXXXXX4316
        Chip Card: CHASE VISA
        AID: A0000000031010
        SEQ #: 15
        Batch #: 972
        INVOICE: 17
        Approval Code: 00093G
        Entry Method: Chip Read
        Mode: Issuer
        PRE-TIP AMT              $66.23
        TIP
        TOTAL AMOUNT
        CUSTOMER COPY
        """
    }

    func testAmountDetectorFindsPrintedAmount() {
        let amounts = ReceiptAmountDetector.amounts(in: naanAndKabobText)
        XCTAssertTrue(amounts.contains("66.23"))
    }

    func testAmountDetectorDoesNotContainFabricatedAmount() {
        let amounts = ReceiptAmountDetector.amounts(in: naanAndKabobText)
        XCTAssertFalse(amounts.contains("142.51"))
    }

    func testAmountDetectorIgnoresBareIntegers() {
        // SEQ #: 15, Batch #: 972, INVOICE: 17 — none of these are money,
        // and must not create false-negative risk for a fabricated amount
        // that happens to collide with one of them. This is the property
        // most at risk from loosening the regex to be locale-agnostic
        // (Part 4 of the currency-setting plan) — must still hold after
        // that change.
        let amounts = ReceiptAmountDetector.amounts(in: naanAndKabobText)
        XCTAssertFalse(amounts.contains("15.00"))
        XCTAssertFalse(amounts.contains("972.00"))
        XCTAssertFalse(amounts.contains("17.00"))
    }

    // MARK: - ReceiptAmountDetector — locale-agnostic separator normalization
    //
    // A receipt's printed number format depends on where the *receipt* was
    // printed, not on the phone's region or the user's AppCurrency display
    // setting — these tests call `separatorNormalized` directly with no
    // locale or currency setting involved, matching that design.

    func testSeparatorNormalizationEuropeanStyle() {
        // European: "." groups, "," is the decimal separator.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1.234,56"), 1234.56)
    }

    func testSeparatorNormalizationUSStyle() {
        // US: "," groups, "." is the decimal separator.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1,234.56"), 1234.56)
    }

    func testSeparatorNormalizationIndianLakhGrouping() {
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1,23,456.78"), 123456.78)
    }

    func testSeparatorNormalizationIndianCroreGrouping() {
        // Indian grouping continues in 2s past lakh — 1,23,45,678.90 is
        // 1 crore 23 lakh 45 thousand 678. The normalization logic already
        // handled any number of grouping separators correctly (it strips
        // every occurrence of whichever char isn't the decimal one,
        // regardless of cluster size), so this was already passing before
        // the regex fix below — it's the *extraction* that needed the fix.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1,23,45,678.90"), 12345678.90)
    }

    // MARK: - ReceiptAmountDetector — end-to-end extraction of Indian grouping
    //
    // Unlike the separatorNormalized tests above, these go through the full
    // amounts(in:) regex scan — the piece that actually needed fixing.
    // Indian grouping clusters in 2s after the first group (unlike Western
    // grouping, always 3), so a regex that only recognized 3-digit clusters
    // would split "1,23,456.78" into "1.23" + "456.78" instead of reading it
    // as one figure.

    func testAmountDetectorExtractsIndianLakhGroupingAsOneToken() {
        let amounts = ReceiptAmountDetector.amounts(in: "TOTAL \u{20B9}1,23,456.78")
        XCTAssertTrue(amounts.contains("123456.78"))
        XCTAssertFalse(amounts.contains("1.23"))
    }

    func testAmountDetectorExtractsIndianCroreGroupingAsOneToken() {
        let amounts = ReceiptAmountDetector.amounts(in: "TOTAL \u{20B9}1,23,45,678.90")
        XCTAssertTrue(amounts.contains("12345678.90"))
    }

    // MARK: - ReceiptAmountDetector — unseparated four-figure totals
    //
    // The leading digit run used to be capped at \d{1,3}, which silently
    // truncated any whole-number part of four digits or more printed
    // without a thousands separator. This was not a theoretical gap: a
    // contractor invoice reading "Total $1001" scanned as $100, so the
    // amount guardrail in `ExtractedReceipt.build` decided the model's
    // correct $1001 "isn't printed on this receipt" and substituted a
    // $390 line item over it. The detector's whole job is to say what is
    // printed, and it was answering with a number that wasn't.

    func testAmountDetectorReadsUnseparatedFourFigureTotal() {
        let amounts = ReceiptAmountDetector.amounts(in: "Total  $1001")
        XCTAssertTrue(amounts.contains("1001.00"))
        // The specific corruption, asserted directly: the first three
        // digits must not match on their own.
        XCTAssertFalse(amounts.contains("100.00"))
    }

    func testAmountDetectorReadsUnseparatedFourFigureAmountWithDecimals() {
        // Worse than the integer case — the cap forced the match to start
        // three digits in, so this used to read as $1.50 rather than
        // failing outright.
        let amounts = ReceiptAmountDetector.amounts(in: "1001.50")
        XCTAssertTrue(amounts.contains("1001.50"))
        XCTAssertFalse(amounts.contains("1.50"))
    }

    func testAmountDetectorStillIgnoresLongBareIntegers() {
        // The counterpart risk of an unbounded leading run: an invoice
        // number is longer than any of the sequence numbers the original
        // bare-integer regression used, and must still be rejected. The
        // rejection lives in the no-symbol branch's required decimal
        // group, not in the leading run's length.
        let amounts = ReceiptAmountDetector.amounts(in: "INVOICE 686301\nSEQ #0123\nBatch 972")
        XCTAssertTrue(amounts.isEmpty)
    }

    func testAmountDetectorIgnoresBareIntegersWithLoosenedGrouping() {
        // The grouping fix above widens (?:[.,]\d{3})* to (?:[.,]\d{2,3})*,
        // which is exactly the kind of change that could accidentally let a
        // 2-digit-suffixed sequence number through. Re-run the bare-integer
        // regression specifically against that change, not just the
        // original locale-agnostic generalization.
        let amounts = ReceiptAmountDetector.amounts(in: naanAndKabobText)
        XCTAssertFalse(amounts.contains("15.00"))
        XCTAssertFalse(amounts.contains("972.00"))
        XCTAssertFalse(amounts.contains("17.00"))
    }

    func testSeparatorNormalizationRepeatedPeriodGrouping() {
        // Only one kind of separator, appearing more than once — can only
        // be grouping.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1.234.567"), 1234567)
    }

    func testSeparatorNormalizationSingleCommaAsDecimal() {
        // One comma, two digits after it — decimal, not grouping.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("342,39"), 342.39)
    }

    func testSeparatorNormalizationSingleCommaAsGrouping() {
        // One comma, three digits after it — grouping.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1,234"), 1234)
    }

    func testSeparatorNormalizationSinglePeriodAsDecimal() {
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("12.5"), 12.5)
    }

    func testSeparatorNormalizationAmbiguousSinglePeriodTreatedAsGrouping() {
        // The one genuinely ambiguous case: could be €1,234 (grouping) or
        // $1.234 (three decimal places). Treated as grouping — three
        // decimal places on a receipt total is far rarer than European
        // thousands grouping.
        XCTAssertEqual(ReceiptAmountDetector.separatorNormalized("1.234"), 1234)
    }

    func testAmountDetectorFindsSymbolPrefixedAmountsForEverySupportedCurrency() {
        for (symbol, expected) in [("$", "66.23"), ("€", "66.23"), ("£", "66.23"), ("₹", "66.23"), ("¥", "66.23")] {
            let amounts = ReceiptAmountDetector.amounts(in: "Total \(symbol)66.23")
            XCTAssertTrue(amounts.contains(expected), "expected to detect \(symbol)66.23")
        }
    }

    // MARK: - ExtractedReceipt.build amount cross-check (sourceText)

    func testPrintedAmountNotFlagged() {
        let r = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: recentDate, amount: "66.23",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: naanAndKabobText)
        XCTAssertEqual(r.amount, "66.23")
        XCTAssertFalse(r.needsReview)
    }

    func testAFabricatedAmountIsReplacedByOneActuallyPrinted() {
        // Policy changed deliberately, and this test now asserts the
        // opposite of what it used to. It previously required "flag only,
        // never auto-correct", on the reasoning that a receipt has too many
        // numbers to safely guess which is the total. That reasoning still
        // holds for *guessing* — and this is not guessing.
        //
        // Two conditions gate it, and both matter: the model's figure has
        // already been shown to appear nowhere on the receipt, and the
        // replacement is one the detector found printed on it. Keeping a
        // number that is provably absent, over one that is provably present,
        // was never the safer choice — it just looked like restraint.
        //
        // What forced the change: on one card slip Apple On-Device produced
        // $13.48, $100.41, $134.48, $187.91, $46.94, $102.31 and $46 across
        // seven scans, none printed anywhere, while the deterministic reader
        // read $89.93 correctly every time from the same OCR text.
        let r = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: recentDate, amount: "142.51",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: naanAndKabobText)
        XCTAssertEqual(r.amount, "66.23", "the printed total should replace one that is not printed")
        XCTAssertTrue(r.needsReview, "Substituting improves the figure; it does not verify it.")
        XCTAssertTrue(r.reviewReason.contains("142.51"),
                      "the rejected figure must still be named, so the correction is auditable")
    }

    func testAFabricatedAmountIsKeptAndFlaggedWhenNothingBetterIsPrinted() {
        // The restraint that survives: with no printed candidate to offer,
        // the model's answer stands rather than being blanked or guessed at.
        // The user can still see what was read.
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: recentDate, amount: "142.51",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: "SOME SHOP, 100 MAIN STREET, ANYTOWN CA 90210 — THANK YOU FOR SHOPPING WITH US TODAY")
        XCTAssertEqual(r.amount, "142.51")
        XCTAssertTrue(r.needsReview)
    }

    func testAmountNormalizationMatchesTrailingZero() {
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: recentDate, amount: "245.6",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: "Total    $245.60")
        XCTAssertFalse(r.needsReview)
    }

    func testNoDetectableAmountLeavesModelAnswerAlone() {
        // Detector finds nothing (unusual/unsupported format) — that means
        // "can't verify," not "the model is wrong." Punishing correct reads
        // on unusual receipts would be worse than not checking at all.
        //
        // Narrowed since: this holds only while `sourceText` is too short to
        // read as a document (see
        // `minimumSourceTextLengthForNoDateRejection`). A *full* page of
        // recognized text containing no currency-shaped figure anywhere is
        // now flagged, because that is what a photographed non-receipt looks
        // like — see `AmountWithNoPrintedAmountsTests`. The fixture below is
        // deliberately short, and that is load-bearing rather than
        // incidental.
        let r = ExtractedReceipt.build(
            vendor: "Some Shop", rawWorkDate: recentDate, amount: "10.00",
            comments: "", rawVendorType: "retail",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: "no currency-shaped text here at all")
        XCTAssertEqual(r.amount, "10.00")
        XCTAssertFalse(r.needsReview)
    }

    func testNilSourceTextSkipsAmountCrossCheck() {
        // Regression guard: omitting sourceText entirely must behave
        // identically to before this change — no amount cross-check at all.
        let r = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: recentDate, amount: "142.51",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.amount, "142.51")
        XCTAssertFalse(r.needsReview)
    }

    // MARK: - ExtractedReceipt.build: a printed gratuity table beats the
    // larger/smaller asymmetry (Masala Bae, real total $47.39)

    /// The printed tip-guideline table shared by both Masala Bae fixtures
    /// below — four rows, each pairing a percentage with the resulting
    /// total, and every one of them printing a LARGER figure than the real
    /// $47.39 total by construction. That shape is what breaks the ordinary
    /// "substitute only when the candidate is larger" rule: the model
    /// reported the 30% row's $61.61, and 47.39 is not larger than 61.61.
    private let masalaBaeTipTable = """
    15%  $7.11   $54.50
    18%  $8.53   $55.92
    20%  $9.48   $56.87
    30%  $14.22  $61.61
    """

    func testAPrintedGratuityTableRowIsCorrectedToTheSameLineTotal() {
        // Real case: Masala Bae's printed "Total $47.39" survives OCR on the
        // same line as its number here, so `BillTotalsParser` finds it
        // directly — but the ordinary third-amount-branch rule ("substitute
        // only when the printed candidate is larger than the model's
        // figure") would keep $61.61 anyway, since 47.39 is smaller, not
        // larger. `isGratuitySuggestionLine` is what breaks that asymmetry
        // for a genuine tip table: the model's $61.61 appears ONLY on a
        // percent-and-amount row, never anywhere else on the receipt, which
        // is proof enough to substitute regardless of size.
        let text = "Total $47.39\n" + masalaBaeTipTable
        let r = ExtractedReceipt.build(
            vendor: "Masala Bae", rawWorkDate: recentDate, amount: "61.61",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        XCTAssertEqual(r.amount, "47.39")
        XCTAssertTrue(r.needsReview, "substitution still improves the figure, it does not verify it")
        XCTAssertTrue(r.reviewReason.contains("47.39"), "the better candidate should be named: \(r.reviewReason)")
    }

    func testAPrintedGratuityTableIsExcludedFromTheSplitColumnFallback() {
        // The other half of the Masala Bae bug: when OCR splits the "Total"
        // label from its own number onto the next line, `BillTotalsParser`
        // finds nothing labeled at all, so `likelyGrandTotal` falls back to
        // "largest amount on the receipt" — and without excluding gratuity
        // rows, that fallback returns the tip table's own 30%-row figure,
        // so nothing even disagrees with the model's $61.61.
        let text = "Total\n$47.39\n" + masalaBaeTipTable
        XCTAssertNotEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "61.61")
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "47.39")

        let r = ExtractedReceipt.build(
            vendor: "Masala Bae", rawWorkDate: recentDate, amount: "61.61",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        XCTAssertEqual(r.amount, "47.39")
        XCTAssertTrue(r.needsReview)
    }

    // MARK: - ExtractedReceipt.build: a COLUMN-WISE printed gratuity table
    // (photo OCR) beats the larger/smaller asymmetry too (Masala Bae again)

    /// The same tip-guideline table as `masalaBaeTipTable` above, but shaped
    /// the way Vision commonly reads it off an actual PHOTO of the receipt
    /// rather than a flat OCR dump: the percent column, the tip column and
    /// the total column each come out as their own run of lines, so no
    /// single line ever carries both a percentage and a dollar amount.
    /// `isGratuitySuggestionLine` — which requires both on the same line —
    /// never matches a single line of this, which is exactly why
    /// `hasGratuitySuggestionTable` exists: it looks at the whole text
    /// instead of line by line.
    private let masalaBaeColumnarTipTable = """
    Tip
    15%
    18%
    20%
    30%
    Amount
    $7.11
    $8.53
    $9.48
    $14.22
    Total
    $54.50
    $55.92
    $56.87
    $61.61
    """

    func testAColumnWiseGratuityTableRowIsCorrectedToThePrintedTotal() {
        // The failing case this task exists to fix: a photographed Masala
        // Bae receipt whose printed "Total $47.39" is on its own line
        // (found directly by `BillTotalsParser`, same as the row-wise
        // fixture above), but whose tip table was read column-wise, so
        // `isGratuitySuggestionLine` never fires for any of it and the old
        // line-shape-only rule would leave the model's $61.61 in place.
        // `hasGratuitySuggestionTable` plus "the model's figure is larger
        // than the printed total on a receipt that has a tip table at all"
        // is what catches it instead.
        // The vendor name has to actually appear near the top of the text
        // here, unlike the shorter row-wise fixture above: that one stays
        // under `topLinesForVendor` and so short-circuits the "near the
        // top" check entirely, but this longer, column-wise text does not,
        // and this test isn't about the vendor cross-check at all.
        let text = "MASALA BAE\nTotal $47.39\n" + masalaBaeColumnarTipTable
        let r = ExtractedReceipt.build(
            vendor: "Masala Bae", rawWorkDate: recentDate, amount: "61.61",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        XCTAssertEqual(r.amount, "47.39")
        XCTAssertTrue(r.needsReview, "substitution still improves the figure, it does not verify it")
        XCTAssertTrue(r.reviewReason.contains("47.39"), "the better candidate should be named: \(r.reviewReason)")
    }

    func testHasGratuitySuggestionTableDetectsTheColumnarCaseByWholeTextPercentageCount() {
        // Two or more DISTINCT percentages is the bar — a suggestion table
        // prints several tiers (15/18/20/30 here).
        XCTAssertTrue(ManualEntryOCRPrefill.hasGratuitySuggestionTable(
            in: "Total $47.39\n" + masalaBaeColumnarTipTable))

        // A single percentage must not qualify — that's the NAAN AND KABOB
        // shape ("Gratuity Guidelines 15% = $13.48"), which the existing
        // line-shape rule already resolves correctly on its own. Widening
        // this to one percentage would start overriding cases that
        // currently resolve right.
        XCTAssertFalse(ManualEntryOCRPrefill.hasGratuitySuggestionTable(
            in: "Sub-total  82.11\nTax  7.82\nGratuity Guidelines 15% = $13.48\nTOTAL  89.93"))

        // No percentage tokens at all — the handwritten-tip card slip case —
        // can never trip this, which is what keeps
        // `testAHandwrittenTipAboveThePrintedTotalIsKept` passing untouched.
        XCTAssertFalse(ManualEntryOCRPrefill.hasGratuitySuggestionTable(
            in: "TOTAL  89.93\nTIP  15.00\n104.93"))
    }

    func testLikelyGrandTotalReturnsNilForAColumnarTipTableWithNoLabeledTotal() {
        // Without a labeled "Total" line anywhere, `BillTotalsParser` finds
        // nothing, and the column-wise table means the per-line gratuity
        // filter that normally protects the "largest number" fallback
        // catches nothing either — every suggested figure, including the
        // 30% row's $61.61, survives into the candidate list looking like
        // an ordinary printed number. On a receipt with a tip table, the
        // fallback's core assumption ("the total is usually the biggest
        // number") is inverted, so it must return nil instead of
        // confidently handing back a suggestion — see `likelyGrandTotal`.
        XCTAssertNil(ManualEntryOCRPrefill.likelyGrandTotal(in: masalaBaeColumnarTipTable))
    }

    func testTheRowWiseMasalaBaeCaseStillResolvesCorrectly() {
        // Guard against the columnar fix above accidentally regressing the
        // row-wise case the previous task already fixed: when OCR keeps
        // percent and dollar on the same line, the per-line filter already
        // excludes every gratuity row on its own, `likelyGrandTotal` still
        // resolves to the real total via the ordinary fallback, and
        // `hasGratuitySuggestionTable` being true besides must not change
        // that answer.
        let text = "Total\n$47.39\n" + masalaBaeTipTable
        XCTAssertTrue(ManualEntryOCRPrefill.hasGratuitySuggestionTable(in: text))
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "47.39")

        let r = ExtractedReceipt.build(
            vendor: "Masala Bae", rawWorkDate: recentDate, amount: "61.61",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: text)
        XCTAssertEqual(r.amount, "47.39")
        XCTAssertTrue(r.needsReview)
    }

    // MARK: - Duplicate detection: tip-shaped amounts widen the date window

    private func entry(_ vendor: String, _ date: String, _ amount: String,
                       vendorType: String = "") -> HistoryEntry {
        HistoryEntry(category: "DTG", vendor: vendor, workDate: date, amount: amount,
                     receiptLink: "\(UUID().uuidString).jpg", timestamp: Date(),
                     vendorType: vendorType)
    }

    func testTipShapedPairFlaggedDespiteDateGapBeyondWindow() {
        // The real Water Grill case: same bill entered twice, once pre-tip
        // and once with tip, and the work date on one copy was read wrong —
        // landing 4 days apart, one day past the 3-day window. Neither the
        // same-date nor the nearby-date rule catches this; the tip ratio
        // (297.39 → 342.39 = +15.13%) is what does.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill South Coast Plaza", "2026-07-26", "342.39"),
            entry("Water Grill South Coast Plaza", "2026-07-30", "297.39"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .possibleTipAdded)
    }

    func testTipShapedPairFlaggedRegardlessOfWhichDateIsLarger() {
        // Direction is deliberately unconstrained — in the real case the
        // EARLIER date carried the with-tip total, so a "later receipt must
        // be the larger one" rule would have rejected a true duplicate.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill", "2026-07-26", "297.39"),
            entry("Water Grill", "2026-07-30", "342.39"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .possibleTipAdded)
    }

    func testNonTipRatioBeyondDateWindowStillNotFlagged() {
        // 40% apart is a separate visit, not a tip — the date window must
        // still apply here, or this change would loosen detection generally
        // instead of only for the tip case.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill", "2026-07-26", "100.00"),
            entry("Water Grill", "2026-07-30", "140.00"),
        ])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testTipShapedPairWithDifferentVendorNotFlagged() {
        // Vendor still gates it — two unrelated businesses whose totals
        // happen to sit ~15% apart are not the same bill.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill", "2026-07-26", "342.39"),
            entry("Zabb Thai Cuisine", "2026-07-30", "297.39"),
        ])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testTipShapedPairIsFlaggedOnceNotTwice() {
        // Within the date window AND tip-shaped — satisfies both conditions,
        // must still produce exactly one pair, not a duplicate entry in the
        // review list.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill", "2026-07-26", "342.39"),
            entry("Water Grill", "2026-07-27", "297.39"),
        ])
        XCTAssertEqual(pairs.count, 1)
    }

    // MARK: - Duplicate detection: the tip waiver is bounded and type-aware

    func testUnrelatedHomeDepotReceiptsNotFlaggedAsTipPair() {
        // The device-testing false positive that motivated the narrowing:
        // two genuinely unrelated Home Depot runs (Costa Mesa vs. Laguna
        // Niguel, different cards, no shared line items) whose totals happen
        // to sit 25% apart — 417.55/333.63 = 1.2515, inside tipRatioRange.
        // 43 days apart and a non-tipping vendor type: both new guards
        // reject it, and nothing else should pair them either.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Home Depot", "2026-07-07", "417.55", vendorType: "hardware_home_improvement"),
            entry("Home Depot", "2026-08-19", "333.63", vendorType: "hardware_home_improvement"),
        ])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testTipShapedPairBeyondTipWindowNotFlaggedEvenAtRestaurant() {
        // Same amounts and dates as the Home Depot case, but at a vendor
        // type where tipping is real — proving the date bound alone rejects
        // it, independently of the vendor-type rule. 43 days is not a
        // misread work date on the same bill.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill", "2026-07-07", "417.55", vendorType: "restaurant"),
            entry("Water Grill", "2026-08-19", "333.63", vendorType: "restaurant"),
        ])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testTipShapedRestaurantPairWithinTipWindowStillFlagged() {
        // The original Water Grill case the exception exists for — 4 days
        // apart, one day past the normal window but well inside the 14-day
        // tip window, at a restaurant. Must still be caught.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Water Grill South Coast Plaza", "2026-07-26", "342.39", vendorType: "restaurant"),
            entry("Water Grill South Coast Plaza", "2026-07-30", "297.39", vendorType: "restaurant"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .possibleTipAdded)
    }

    func testTipShapedHardwarePairWithinTipWindowNotLabeledTip() {
        // Same 4-day gap as the case above, so the date bound alone would
        // allow it — only the vendor-type rule stops it. Nobody tips at a
        // hardware store, so a 15% ratio there is two different-sized
        // shopping trips. With the tip signal suppressed the pair falls back
        // to the ordinary date rule, and 4 days is outside the 3-day
        // nearbyDateWindow, so it isn't flagged at all.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Home Depot", "2026-07-26", "342.39", vendorType: "hardware_home_improvement"),
            entry("Home Depot", "2026-07-30", "297.39", vendorType: "hardware_home_improvement"),
        ])
        XCTAssertTrue(pairs.allSatisfy { $0.confidence != .possibleTipAdded })
        XCTAssertTrue(pairs.isEmpty)
    }

    func testSuppressedTipSignalStillFlagsViaNearbyDateRule() {
        // The interaction worth pinning down: suppressing the tip signal
        // must not suppress the pair. Two days apart at a hardware store is
        // still within nearbyDateWindow, so Signal 2 flags it — just with
        // the honest "check the date and amount" label instead of claiming
        // a tip explains the difference.
        let pairs = DuplicateDetectionService.findPairs(in: [
            entry("Home Depot", "2026-07-26", "342.39", vendorType: "hardware_home_improvement"),
            entry("Home Depot", "2026-07-28", "297.39", vendorType: "hardware_home_improvement"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .possibleDifferentDateAndAmount)
    }

    func testTipSignalAllowedWhenVendorTypeUnknown() {
        // Conservative rule: only a POSITIVELY known non-tipping type
        // suppresses. Empty (manual entries and everything saved before the
        // field existed), a user-defined custom type, and `other` are all
        // unclassifiable, so the tip signal still applies — otherwise this
        // change would silently switch the rule off for the whole existing
        // history.
        for type in ["", "Tiki Bar", "other"] {
            let pairs = DuplicateDetectionService.findPairs(in: [
                entry("Water Grill", "2026-07-26", "342.39", vendorType: type),
                entry("Water Grill", "2026-07-30", "297.39", vendorType: type),
            ])
            XCTAssertEqual(pairs.count, 1, "vendorType \"\(type)\"")
            XCTAssertEqual(pairs.first?.confidence, .possibleTipAdded, "vendorType \"\(type)\"")
        }
    }
}

/// Tests for the search date resolver — the Swift half of natural-language
/// date filtering. The parsing itself (phrase -> descriptor) lives in a live
/// model and has no mockable seam, but everything that decides what a phrase
/// *means* is here, deterministic and anchored on an injected `now` rather
/// than the real clock. This is the regression net for the bug these exist
/// for: date phrases used to be dropped silently, so a query like "anything
/// from 2 weeks ago" returned the whole history looking like a filtered set.
final class SearchDateResolverTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    private func date(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: string)!
    }

    private func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = AppConstants.sheetDateFormat
        return f.string(from: date)
    }

    private func resolve(_ kind: QueryDateRangeKind, count: Int? = nil, month: Int? = nil,
                         year: Int? = nil, now: String) -> (from: String, to: String)? {
        let descriptor = QueryDateDescriptor(kind: kind, count: count, month: month, year: year)
        guard let range = SearchDateResolver.resolve(descriptor, now: date(now), calendar: calendar) else { return nil }
        return (day(range.from), day(range.to))
    }

    // MARK: - No date phrase at all

    func testNoDatePhraseProducesNoRange() {
        // The behavior every pre-existing query depends on: nothing named,
        // nothing filtered, no chip.
        XCTAssertNil(resolve(.none, now: "2026-08-18 14:00:00"))
    }

    func testUnknownTokenProducesNoRangeButIsReported() {
        // CHANGED BEHAVIOR (was `testUnknownTokenFallsBackToNoRange`). This
        // test used to assert only the first half — no range — which is the
        // silent-drop bug written down as a specification: an invented token
        // meant the date half of the query vanished and the caller could not
        // tell the difference between "the query named no time period" and
        // "the query named one I couldn't express". The user then saw an
        // unfiltered history with a filter chip on it. Producing no range is
        // still correct; staying quiet about it is not.
        let dates = SearchDateResolver.range(from: ["date_range_kind": "sometime_recently"],
                                             now: date("2026-08-18 14:00:00"))
        XCTAssertNil(dates.from)
        XCTAssertNil(dates.to)
        XCTAssertEqual(dates.unrecognizedToken, "sometime_recently")
    }

    func testExplicitNoneIsNotReportedAsUnrecognized() {
        // "none" is a legitimate answer and must stay distinguishable from an
        // invented token, or every ordinary query would start erroring.
        for token in ["none", "", "null", "  None  "] {
            let dates = SearchDateResolver.range(from: ["date_range_kind": token],
                                                 now: date("2026-08-18 14:00:00"))
            XCTAssertNil(dates.unrecognizedToken, "token \(token) should read as none")
        }
    }

    func testMissingTokenIsNotReportedAsUnrecognized() {
        let dates = SearchDateResolver.range(from: [:], now: date("2026-08-18 14:00:00"))
        XCTAssertNil(dates.unrecognizedToken)
    }

    func testRecognizedTokenIsNotReportedAsUnrecognized() {
        let dates = SearchDateResolver.range(from: ["date_range_kind": "last_month"],
                                             now: date("2026-08-18 14:00:00"))
        XCTAssertNil(dates.unrecognizedToken)
        XCTAssertNotNil(dates.from)
    }

    func testLastNDaysWithoutCountProducesNoRange() {
        XCTAssertNil(resolve(.lastNDays, now: "2026-08-18 14:00:00"))
    }

    // MARK: - Relative windows

    func testTwoWeeksAgoIsTheLastFourteenDaysIncludingToday() {
        // "2 weeks ago" is a window, not the single day 14 days back —
        // Aug 5 through Aug 18 inclusive is 14 days.
        let range = resolve(.lastNDays, count: 14, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-08-05")
        XCTAssertEqual(range?.to, "2026-08-18")
    }

    func testLastNDaysStartsAtMidnightAndEndsAtEndOfToday() {
        let descriptor = QueryDateDescriptor(kind: .lastNDays, count: 7)
        let range = SearchDateResolver.resolve(descriptor, now: date("2026-08-18 14:00:00"), calendar: calendar)
        // A receipt scanned at 11pm today must still be inside the window.
        XCTAssertEqual(range?.from, date("2026-08-12 00:00:00"))
        XCTAssertTrue(range!.to > date("2026-08-18 23:00:00"))
        XCTAssertTrue(range!.to < date("2026-08-19 00:00:00"))
    }

    func testLastNDaysCrossesAMonthBoundary() {
        let range = resolve(.lastNDays, count: 14, now: "2026-03-05 09:30:00")
        XCTAssertEqual(range?.from, "2026-02-20")
        XCTAssertEqual(range?.to, "2026-03-05")
    }

    // MARK: - Calendar periods

    func testThisMonthIsMonthToDate() {
        let range = resolve(.thisMonth, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-08-01")
        XCTAssertEqual(range?.to, "2026-08-18")
    }

    func testLastMonthSpansAYearBoundary() {
        // The edge case worth pinning: "last month" asked in January is the
        // previous December, not month zero of the same year.
        let range = resolve(.lastMonth, now: "2026-01-09 08:00:00")
        XCTAssertEqual(range?.from, "2025-12-01")
        XCTAssertEqual(range?.to, "2025-12-31")
    }

    func testLastMonthHandlesShortMonths() {
        let range = resolve(.lastMonth, now: "2026-03-15 08:00:00")
        XCTAssertEqual(range?.from, "2026-02-01")
        XCTAssertEqual(range?.to, "2026-02-28")
    }

    func testLastYearIsTheWholePreviousYear() {
        let range = resolve(.lastYear, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2025-01-01")
        XCTAssertEqual(range?.to, "2025-12-31")
    }

    func testThisYearIsYearToDate() {
        let range = resolve(.thisYear, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-01-01")
        XCTAssertEqual(range?.to, "2026-08-18")
    }

    func testLastWeekIsThePreviousCalendarWeek() {
        // Gregorian week starts Sunday in en_US_POSIX: the week before the
        // one containing Wed Aug 18 2026 is Sun Aug 8 - Sat Aug 14.
        let range = resolve(.lastWeek, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-08-09")
        XCTAssertEqual(range?.to, "2026-08-15")
    }

    // MARK: - Named months and years

    func testNamedMonthAlreadyPassedResolvesToThisYear() {
        let range = resolve(.namedMonth, month: 7, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-07-01")
        XCTAssertEqual(range?.to, "2026-07-31")
    }

    func testNamedMonthStillInTheFutureResolvesToLastYear() {
        // "July" said in March: nobody searches receipts they haven't
        // collected yet, so it means last July.
        let range = resolve(.namedMonth, month: 7, now: "2026-03-02 14:00:00")
        XCTAssertEqual(range?.from, "2025-07-01")
        XCTAssertEqual(range?.to, "2025-07-31")
    }

    func testNamedMonthIsTheCurrentMonthWhenItIsTheCurrentMonth() {
        // Boundary of the future-month rule: August in August stays 2026.
        let range = resolve(.namedMonth, month: 8, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2026-08-01")
        XCTAssertEqual(range?.to, "2026-08-31")
    }

    func testNamedMonthWithExplicitYearIgnoresTheFutureRule() {
        let range = resolve(.namedMonth, month: 7, year: 2024, now: "2026-03-02 14:00:00")
        XCTAssertEqual(range?.from, "2024-07-01")
        XCTAssertEqual(range?.to, "2024-07-31")
    }

    func testInvalidMonthNumberProducesNoRange() {
        XCTAssertNil(resolve(.namedMonth, month: 13, now: "2026-08-18 14:00:00"))
    }

    func testSpecificYear() {
        let range = resolve(.specificYear, year: 2024, now: "2026-08-18 14:00:00")
        XCTAssertEqual(range?.from, "2024-01-01")
        XCTAssertEqual(range?.to, "2024-12-31")
    }

    // MARK: - Descriptor extraction from provider JSON

    func testRangeFromProviderFieldsTreatsSentinelsAsAbsent() {
        // The on-device model writes -1 where a field doesn't apply; the
        // cloud parsers write null. Neither may be read as a real count.
        let dates = SearchDateResolver.range(
            from: ["date_range_kind": "last_month", "date_count": -1, "date_month": -1, "date_year": -1],
            now: date("2026-01-09 08:00:00"))
        XCTAssertEqual(dates.from.map(day), "2025-12-01")
        XCTAssertEqual(dates.to.map(day), "2025-12-31")
    }

    func testRangeFromProviderFieldsReadsLastNDays() {
        let dates = SearchDateResolver.range(
            from: ["date_range_kind": "last_n_days", "date_count": 14],
            now: date("2026-08-18 14:00:00"))
        XCTAssertEqual(dates.from.map(day), "2026-08-05")
        XCTAssertEqual(dates.to.map(day), "2026-08-18")
    }

    // MARK: - Chip labels

    func testWholeMonthLabelsAsMonthAndYear() {
        let range = SearchDateResolver.resolve(QueryDateDescriptor(kind: .namedMonth, month: 7),
                                               now: date("2026-08-18 14:00:00"), calendar: calendar)!
        XCTAssertEqual(SearchDateResolver.label(from: range.from, to: range.to,
                                                now: date("2026-08-18 14:00:00"), calendar: calendar),
                       "Jul 2026")
    }

    func testWindowEndingTodayLabelsAsLastNDays() {
        let range = SearchDateResolver.resolve(QueryDateDescriptor(kind: .lastNDays, count: 14),
                                               now: date("2026-08-18 14:00:00"), calendar: calendar)!
        XCTAssertEqual(SearchDateResolver.label(from: range.from, to: range.to,
                                                now: date("2026-08-18 14:00:00"), calendar: calendar),
                       "Last 14 days")
    }

    func testArbitraryRangeLabelsWithBothEnds() {
        let range = SearchDateResolver.resolve(QueryDateDescriptor(kind: .lastWeek),
                                               now: date("2026-08-18 14:00:00"), calendar: calendar)!
        XCTAssertEqual(SearchDateResolver.label(from: range.from, to: range.to,
                                                now: date("2026-08-18 14:00:00"), calendar: calendar),
                       "Aug 9 – Aug 15")
    }

    // MARK: - QueryParseResult.isEmpty

    func testDateOnlyFilterIsNotEmpty() {
        // isEmpty gates whether any filter is applied at all: a date-only
        // query must count as a real filter, or the range would be parsed
        // and then thrown away — the original bug.
        let result = QueryParseResult(vendorType: nil, amountMin: nil, amountMax: nil,
                                      dateFrom: date("2026-08-05 00:00:00"), dateTo: date("2026-08-18 23:59:59"))
        XCTAssertFalse(result.isEmpty)
    }

    func testFullyEmptyResultIsEmpty() {
        XCTAssertTrue(QueryParseResult(vendorType: nil, amountMin: nil, amountMax: nil).isEmpty)
    }
}

private extension DateFormatter {
    static let posixDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return f
    }()
}

/// Tests for the deterministic Swift passes that now sit on either side of
/// the search-query models — `SearchQueryDateParser` before, and
/// `SearchVendorTypeGuard` / `SemanticSearchService.finalize` after.
///
/// These exist because prompt-only fixes for the on-device model have failed
/// three times running (the $100–$100 amount bound, the "other" vendor type,
/// the date fields). Everything below is model-free and fully deterministic,
/// which is the entire argument for moving these guarantees into Swift: they
/// can be pinned by a test, and a prompt cannot.
final class SearchQueryGuardTests: XCTestCase {

    // Deliberately `Calendar.current` rather than a fixed test calendar.
    // `NSDataDetector` resolves "August 4th" in the *current* time zone, and
    // pinning the assertions to a different one would make these tests fail
    // on some machines and pass on others for reasons having nothing to do
    // with the code under test.
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func day(_ value: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: value)
    }

    private func parse(_ query: String, now: Date) -> (from: String, to: String)? {
        guard let range = SearchQueryDateParser.explicitRange(in: query, now: now, calendar: calendar) else {
            return nil
        }
        return (day(range.from), day(range.to))
    }

    // MARK: - Spelled-out dates (the reported bug)

    func testSpelledOutDateInTheReportedQuery() {
        // The exact query from the device report. It produced no date filter
        // at all, because the descriptor vocabulary has no way to name a
        // single calendar day.
        let range = parse("anything on August 4th receipt date", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testSpelledOutDateWithoutOrdinalSuffix() {
        let range = parse("receipts on August 4", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testSpelledOutDateWithExplicitYearUsesThatYear() {
        let range = parse("anything from August 4 2025", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-08-04")
        XCTAssertEqual(range?.to, "2025-08-04")
    }

    func testSpelledOutDateStillInTheFutureResolvesToLastYear() {
        // Asked in August, "December 4th" cannot mean the December that
        // hasn't happened — the same rule `SearchDateResolver` already
        // applies to a bare named month.
        let range = parse("anything on December 4th", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-12-04")
    }

    // MARK: - Numeric dates

    func testNumericDateWithFourDigitYear() {
        let range = parse("receipts on 08/04/2026", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testNumericDateWithTwoDigitYear() {
        let range = parse("anything on 8/4/26", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
    }

    func testBareMonthDayInfersTheMostRecentPastYear() {
        let range = parse("anything on 8/4", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testBareMonthDayStillAheadOfTodayResolvesToLastYear() {
        let range = parse("anything on 12/4", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-12-04")
    }

    func testDayGreaterThanTwelveForcesDayMonthOrdering() {
        let range = parse("receipts on 25/12/2025", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-12-25")
    }

    func testImpossibleCalendarDateIsNotInvented() {
        // Never let Calendar normalize 02/30 into March 2 — fabricating a
        // date the user didn't type is the failure mode all of this exists
        // to prevent.
        XCTAssertNil(parse("receipts on 02/30/2026", now: date(2026, 8, 28)))
    }

    // MARK: - Explicit ranges

    func testExplicitRangeBetweenTwoSpelledOutDates() {
        let range = parse("between Aug 1 and Aug 10", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-01")
        XCTAssertEqual(range?.to, "2026-08-10")
    }

    func testExplicitRangeBetweenTwoNumericDates() {
        let range = parse("from 8/1/26 to 8/15/26", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-01")
        XCTAssertEqual(range?.to, "2026-08-15")
    }

    // MARK: - Negative cases: money queries must never gain a date filter

    func testAmountQueryOverProducesNoDate() {
        XCTAssertNil(parse("receipts over 100", now: date(2026, 8, 28)))
    }

    func testAmountQueryUnderProducesNoDate() {
        XCTAssertNil(parse("under 50", now: date(2026, 8, 28)))
    }

    func testAmountRangeQueryProducesNoDate() {
        // The specific risk called out in review: NSDataDetector reads
        // "between X and Y" phrasing as a date span. Without the
        // month-name-or-separator gate this becomes a date filter stapled to
        // a money query.
        XCTAssertNil(parse("between 20 and 40", now: date(2026, 8, 28)))
    }

    func testHyphenatedAmountRangeProducesNoDate() {
        // Why the yearless pattern accepts "/" only: "5-10" is a money range,
        // not May 10.
        XCTAssertNil(parse("receipts between 5-10 dollars", now: date(2026, 8, 28)))
    }

    // MARK: - Bare month names (the reported bug)
    //
    // "Receipts from July" used to come back "No Matches": there is no day
    // number in it, so the old day-only pass found nothing and the query
    // fell through to the AI parser, which failed to emit `named_month` for
    // it. These pin the deterministic fix — `namedMonthRange` — directly,
    // using the same `SearchDateResolver` arithmetic already proven by
    // `SearchDateResolverTests`, never a second copy of it.

    func testTheReportedQueryResolvesToTheWholeMonth() {
        let range = parse("Receipts from July", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2026-07-01")
        XCTAssertEqual(range?.to, "2026-07-31")
    }

    func testInJulyResolvesTheSameAsTheReportedQuery() {
        let range = parse("in July", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2026-07-01")
        XCTAssertEqual(range?.to, "2026-07-31")
    }

    func testBareJulyWithNoOtherWordsResolvesTheSameWay() {
        let range = parse("July", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2026-07-01")
        XCTAssertEqual(range?.to, "2026-07-31")
    }

    func testAMonthThatHasNotHappenedYetThisYearMeansLastYear() {
        // Asked in September, "December" cannot mean the December that
        // hasn't arrived yet — the same rule `SearchDateResolver` already
        // applies to the model's `named_month` descriptor.
        let range = parse("December", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2025-12-01")
        XCTAssertEqual(range?.to, "2025-12-31")
    }

    func testMonthAndYearHonorsTheStatedYear() {
        // Overrides the "hasn't happened yet" rule — the year was stated
        // outright, so there is nothing left to infer.
        let range = parse("anything from July 2025", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-07-01")
        XCTAssertEqual(range?.to, "2025-07-31")
    }

    func testASpecificDayStillWinsOverTheMonthItFallsIn() {
        // "August 4th" names both a day and a month; the day is what the
        // user means, not the whole month around it. Must return the single
        // day, not July 1 - July 31 or August 1 - August 31.
        let range = parse("anything on August 4th", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testANumericDayStillWinsOverTheMonthItFallsIn() {
        let range = parse("anything on 8/4", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-04")
        XCTAssertEqual(range?.to, "2026-08-04")
    }

    func testMayIsNotConfusedWithTheOrdinaryEnglishWord() {
        // "May" doubles as a modal verb. An unrelated query that happens to
        // contain it must not silently turn into a date filter.
        XCTAssertNil(parse("receipts I may have missed", now: date(2026, 8, 28)))
    }

    func testInMayIsUnambiguousAndResolves() {
        let range = parse("in May", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-05-01")
        XCTAssertEqual(range?.to, "2026-05-31")
    }

    func testMayWithAYearIsUnambiguousAndResolves() {
        let range = parse("May 2025", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2025-05-01")
        XCTAssertEqual(range?.to, "2025-05-31")
    }

    func testVendorNameContainingAMonthWordIsNotMisreadAsADate() {
        // The important regression guard: "Marchetti's" must not resolve to
        // March. `\bmarch\b` cannot match inside "marchetti's" because there
        // is no word boundary between "march" and "etti's" — but this test
        // exists so a future edit that loosens the match (e.g. to
        // `contains`) fails loudly instead of shipping a search that quietly
        // stops finding this vendor's receipts.
        XCTAssertNil(parse("Marchetti's", now: date(2026, 8, 28)))
        XCTAssertNil(parse("receipts from Marchetti's", now: date(2026, 8, 28)))
    }

    // MARK: - Relative periods and bare years (the amounts/vendor-type widening)
    //
    // These phrases used to fall all the way through to the model's
    // `date_range_kind` field — see `testRelativePhrasesAreLeftToTheModel`'s
    // old name and the file-level comment on `explicitRange`'s widened scope.
    // Every arithmetic answer below is `SearchDateResolver`'s, not a new copy
    // of it; these tests exist to pin that `SearchQueryDateParser` finds the
    // right phrase and hands it to the resolver correctly, the same
    // division of labor `namedMonthRange` already has above.

    func testRelativePhrasesNowResolveDeterministically() {
        let twoWeeksAgo = parse("anything from 2 weeks ago", now: date(2026, 8, 28))
        XCTAssertEqual(twoWeeksAgo?.from, "2026-08-15")
        XCTAssertEqual(twoWeeksAgo?.to, "2026-08-28")

        let last30Days = parse("in the last 30 days", now: date(2026, 8, 28))
        XCTAssertEqual(last30Days?.from, "2026-07-30")
        XCTAssertEqual(last30Days?.to, "2026-08-28")

        let lastMonth = parse("from last month", now: date(2026, 8, 28))
        XCTAssertEqual(lastMonth?.from, "2026-07-01")
        XCTAssertEqual(lastMonth?.to, "2026-07-31")

        let thisMonth = parse("so far this month", now: date(2026, 8, 28))
        XCTAssertEqual(thisMonth?.from, "2026-08-01")
        XCTAssertEqual(thisMonth?.to, "2026-08-28")
    }

    func testLastWeekAndThisWeekResolve() {
        XCTAssertNotNil(parse("receipts from last week", now: date(2026, 9, 13)))
        let thisWeek = parse("anything from this week", now: date(2026, 9, 13))
        XCTAssertEqual(thisWeek?.to, "2026-09-13")
    }

    func testLastYearAndThisYearResolve() {
        let lastYear = parse("receipts from last year", now: date(2026, 9, 13))
        XCTAssertEqual(lastYear?.from, "2025-01-01")
        XCTAssertEqual(lastYear?.to, "2025-12-31")

        let thisYear = parse("grocery receipts under $100 this year", now: date(2026, 9, 13))
        XCTAssertEqual(thisYear?.from, "2026-01-01")
        XCTAssertEqual(thisYear?.to, "2026-09-13")
    }

    func testSpelledOutWeeksAgoMultiplyIntoADayCount() {
        // "three weeks ago" -> 21 days, the same "whole recent window, not
        // one single day" reading `SearchDateResolver` already documents for
        // "2 weeks ago".
        let range = parse("three weeks ago", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-08")
        XCTAssertEqual(range?.to, "2026-08-28")
    }

    func testPastNWeeksMultipliesIntoADayCount() {
        let range = parse("past 2 weeks", now: date(2026, 8, 28))
        XCTAssertEqual(range?.from, "2026-08-15")
        XCTAssertEqual(range?.to, "2026-08-28")
    }

    func testBareYearResolvesToTheWholeCalendarYear() {
        let range = parse("receipts from 2026", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2026-01-01")
        XCTAssertEqual(range?.to, "2026-12-31")
    }

    func testDollarAmountShapedLikeAYearIsNotReadAsAYear() {
        // 1500 sits outside the plausible 2000-2100 window, so it can never
        // be misread as a year no matter how it's phrased.
        XCTAssertNil(parse("receipts over 1500", now: date(2026, 9, 13)))
    }

    func testTheReportedJulyQueryStillResolvesWithTheNewNow() {
        // Pinned again at the fixed `now` this task's whole test list uses,
        // so the older month-name pass and the new relative/year passes are
        // proven to coexist correctly at the same point in time.
        let range = parse("receipts from July", now: date(2026, 9, 13))
        XCTAssertEqual(range?.from, "2026-07-01")
        XCTAssertEqual(range?.to, "2026-07-31")
    }

    func testQueryWithNoDateAtAllProducesNothing() {
        XCTAssertNil(parse("restaurant receipts", now: date(2026, 8, 28)))
        XCTAssertNil(parse("the notary place", now: date(2026, 8, 28)))
    }

    // MARK: - The "other" guard

    func testOtherIsDroppedWhenTheQueryNamesNoBusinessType() {
        // The reported regression: an "Other" chip on a query that names no
        // business at all.
        XCTAssertNil(SearchVendorTypeGuard.sanitized("other", query: "anything on August 4th receipt date"))
        XCTAssertNil(SearchVendorTypeGuard.sanitized("other", query: "anything from 2 weeks ago"))
        XCTAssertNil(SearchVendorTypeGuard.sanitized("other", query: "receipts over 50"))
    }

    func testOtherSurvivesWhenTheQueryActuallyNamesABusiness() {
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("other", query: "the notary place"), "other")
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("other", query: "other receipts"), "other")
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("other", query: "miscellaneous vendors"), "other")
    }

    func testGuardNeverTouchesAnyOtherVendorType() {
        // The reason this is scoped to "other" alone: these are semantic
        // mappings the model is good at, and none of the queries contain the
        // token's own word. A lexical check applied to them would break
        // ordinary, working searches.
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("restaurant", query: "dinner last week"), "restaurant")
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("gas_station", query: "filled up the truck"), "gas_station")
        XCTAssertEqual(SearchVendorTypeGuard.sanitized("lodging", query: "where did I stay in Denver"), "lodging")
    }

    func testGuardMatchesWholeWordsOnly() {
        // "another" must not license "other"; "carpet" must not license "car".
        XCTAssertNil(SearchVendorTypeGuard.sanitized("other", query: "another receipt from yesterday"))
        XCTAssertNil(SearchVendorTypeGuard.sanitized("other", query: "carpet cleaning"))
    }

    func testGuardPassesThroughEmptyAndNil() {
        XCTAssertNil(SearchVendorTypeGuard.sanitized(nil, query: "anything"))
        XCTAssertNil(SearchVendorTypeGuard.sanitized("", query: "anything"))
    }

    // MARK: - finalize: how the two passes combine

    private func result(vendorType: String? = nil, amountMin: Double? = nil, amountMax: Double? = nil,
                        dateFrom: Date? = nil, dateTo: Date? = nil,
                        unrecognizedDateToken: String? = nil) -> QueryParseResult {
        QueryParseResult(vendorType: vendorType, amountMin: amountMin, amountMax: amountMax,
                         dateFrom: dateFrom, dateTo: dateTo, unrecognizedDateToken: unrecognizedDateToken)
    }

    func testFinalizeAppliesTheExplicitDateOverTheModels() {
        // The pre-pass read the date out of the query text directly, so the
        // model's opinion about dates is discarded — including a whole-month
        // range it may have guessed at.
        let explicit = (from: date(2026, 8, 4, hour: 0), to: date(2026, 8, 4, hour: 23))
        let out = try? SemanticSearchService.finalize(
            result(dateFrom: date(2026, 8, 1), dateTo: date(2026, 8, 31)),
            query: "anything on August 4th", explicit: explicit)
        XCTAssertEqual(out?.dateFrom, explicit.from)
        XCTAssertEqual(out?.dateTo, explicit.to)
    }

    func testFinalizeDropsOtherAndKeepsAmounts() {
        let out = try? SemanticSearchService.finalize(
            result(vendorType: "other", amountMin: 50),
            query: "receipts over 50", explicit: nil)
        XCTAssertNil(out?.vendorType)
        XCTAssertEqual(out?.amountMin, 50)
    }

    func testFinalizeThrowsRatherThanShowingAnUnfilteredList() {
        // The core of the silent-drop fix. A model that named a time period
        // it had no token for must not produce a result that looks filtered.
        XCTAssertThrowsError(try SemanticSearchService.finalize(
            result(vendorType: "restaurant", unrecognizedDateToken: "specific_date"),
            query: "restaurants on August 4th", explicit: nil))
    }

    func testFinalizeDoesNotThrowWhenTheExplicitPassCoveredIt() {
        // An unrecognized token is harmless once Swift has read the date
        // itself — there is nothing left to be silent about.
        let explicit = (from: date(2026, 8, 4, hour: 0), to: date(2026, 8, 4, hour: 23))
        XCTAssertNoThrow(try SemanticSearchService.finalize(
            result(unrecognizedDateToken: "specific_date"),
            query: "anything on August 4th", explicit: explicit))
    }

    func testFinalizeLeavesAnOrdinaryResultAlone() {
        let out = try? SemanticSearchService.finalize(
            result(vendorType: "restaurant", amountMin: 20, dateFrom: date(2026, 7, 1), dateTo: date(2026, 7, 31)),
            query: "restaurant receipts over 20 in July", explicit: nil)
        XCTAssertEqual(out?.vendorType, "restaurant")
        XCTAssertEqual(out?.amountMin, 20)
        XCTAssertNotNil(out?.dateFrom)
    }

    // MARK: - SearchAmountParser: bound phrases

    func testOverPlusSpelledOutHundred() {
        let bounds = SearchAmountParser.bounds(in: "restaurants over hundred dollars")
        XCTAssertEqual(bounds.min, 100)
        XCTAssertNil(bounds.max)
    }

    func testOverPlusDollarSign() {
        let bounds = SearchAmountParser.bounds(in: "receipts over $100")
        XCTAssertEqual(bounds.min, 100)
    }

    func testUnderPlusSpelledOutFifty() {
        let bounds = SearchAmountParser.bounds(in: "gas station receipts under fifty dollars")
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(bounds.min)
    }

    func testBelowPlusDollarSign() {
        let bounds = SearchAmountParser.bounds(in: "anything below $20")
        XCTAssertEqual(bounds.max, 20)
    }

    func testBetweenRangeOrdersLowToHigh() {
        let bounds = SearchAmountParser.bounds(in: "receipts between 20 and 40 dollars")
        XCTAssertEqual(bounds.min, 20)
        XCTAssertEqual(bounds.max, 40)
    }

    func testMoreThanPlusSpelledOutCompound() {
        let bounds = SearchAmountParser.bounds(in: "restaurants more than two hundred dollars")
        XCTAssertEqual(bounds.min, 200)
    }

    func testAtLeastIgnoresTrailingVendorName() {
        // Vendor-name search is out of scope for this task — only the amount
        // bound is asserted, per the task's own constraint.
        let bounds = SearchAmountParser.bounds(in: "at least $75 at Home Depot")
        XCTAssertEqual(bounds.min, 75)
    }

    func testNoMoreThanIsAnUpperBoundNotALowerOne() {
        // The one real collision between the two phrase lists: "no more
        // than" contains the complete lower-bound phrase "more than" as a
        // substring. Pins that the upper-bound reading wins.
        let bounds = SearchAmountParser.bounds(in: "no more than $50")
        XCTAssertEqual(bounds.max, 50)
        XCTAssertNil(bounds.min)
    }

    func testHyphenatedRangeWithNoBetweenKeyword() {
        let bounds = SearchAmountParser.bounds(in: "receipts 100-150")
        XCTAssertEqual(bounds.min, 100)
        XCTAssertEqual(bounds.max, 150)
    }

    // MARK: - SearchAmountParser: must produce no bounds at all

    func testVagueWordsProduceNoBounds() {
        for query in ["cheap restaurant visits", "expensive receipts", "receipts around $50"] {
            let bounds = SearchAmountParser.bounds(in: query)
            XCTAssertNil(bounds.min, query)
            XCTAssertNil(bounds.max, query)
        }
    }

    // MARK: - SearchAmountParser: regression guards

    func testFromJulyIsNeverReadAsAnAmountLowerBound() {
        let bounds = SearchAmountParser.bounds(in: "from July")
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    func testFromABareYearIsNeverReadAsAnAmountEither() {
        // The same guard, aimed at the number rather than the word: "from
        // 2026" must stay a date, not a $2026 minimum.
        let bounds = SearchAmountParser.bounds(in: "receipts from 2026")
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    func testVendorNameWithAMonthFragmentProducesNoAmountBound() {
        // Mirrors `testVendorNameContainingAMonthWordIsNotMisreadAsADate` on
        // the money side: "Marchetti's" contains no number at all, so there
        // is nothing here to misread either.
        let bounds = SearchAmountParser.bounds(in: "Marchetti's")
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    func testVendorNameQueryProducesNoAmountAndNoDate() {
        XCTAssertNil(parse("anything from Starbucks", now: date(2026, 9, 13)))
        let bounds = SearchAmountParser.bounds(in: "anything from Starbucks")
        XCTAssertNil(bounds.min)
        XCTAssertNil(bounds.max)
    }

    // MARK: - SearchVendorTypeKeywords

    func testGroceryKeywordFillsInAnUnclassifiedQuery() {
        XCTAssertEqual(SearchVendorTypeKeywords.match(in: "show me all grocery receipts"), "grocery")
    }

    func testHardwareStorePhraseResolves() {
        XCTAssertEqual(SearchVendorTypeKeywords.match(in: "hardware store purchases"), "hardware_home_improvement")
    }

    func testMedicalExpensesPhraseResolves() {
        XCTAssertEqual(SearchVendorTypeKeywords.match(in: "medical expenses"), "medical")
    }

    func testKeywordFallbackFindsNothingInAnUnrelatedQuery() {
        XCTAssertNil(SearchVendorTypeKeywords.match(in: "receipts over 50"))
    }

    // MARK: - finalize: amounts and vendor-type keywords combined

    func testFinalizeCombinesRestaurantKeywordWithAnUpperBound() {
        let out = try? SemanticSearchService.finalize(
            result(), query: "restaurant receipts under $30", explicit: nil)
        XCTAssertEqual(out?.vendorType, "restaurant")
        XCTAssertEqual(out?.amountMax, 30)
        XCTAssertNil(out?.amountMin)
    }

    func testFinalizeCombinesGasStationKeywordWithALowerBound() {
        let out = try? SemanticSearchService.finalize(
            result(), query: "gas station over 40", explicit: nil)
        XCTAssertEqual(out?.vendorType, "gas_station")
        XCTAssertEqual(out?.amountMin, 40)
    }

    func testFinalizeDropsAModelInventedAmountWhenTheQueryHasNoNumber() {
        // The core of the "stop the model inventing amounts" fix: the model
        // returned a bound for a query that names no number anywhere, so it
        // must be discarded rather than shown as a filter the user asked for.
        let out = try? SemanticSearchService.finalize(
            result(amountMin: 40), query: "expensive receipts", explicit: nil)
        XCTAssertNil(out?.amountMin)
        XCTAssertNil(out?.amountMax)
    }

    func testFinalizeKeepsAModelAmountWhenTheQueryHasANumberTheParserDidNotRecognize() {
        // "Around $50" contains a number but no phrase this parser's fixed
        // list recognizes as a bound. Unlike the no-number case above, the
        // model's answer survives here — it may have understood a nuance the
        // deterministic list doesn't yet.
        let out = try? SemanticSearchService.finalize(
            result(amountMax: 55), query: "receipts around $50", explicit: nil)
        XCTAssertEqual(out?.amountMax, 55)
    }

    func testFinalizeAmountParserOverridesTheModelWhenBothAnswer() {
        let out = try? SemanticSearchService.finalize(
            result(amountMin: 999), query: "receipts over $100", explicit: nil)
        XCTAssertEqual(out?.amountMin, 100)
    }

    // MARK: - Chip label for a single day

    func testSingleDayLabelsAsOneDate() {
        // Without this the now-common single-date filter would read
        // "Aug 4 – Aug 4".
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let from = cal.date(from: DateComponents(year: 2026, month: 8, day: 4))!
        let to = cal.date(byAdding: .day, value: 1, to: from)!.addingTimeInterval(-1)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 14))!
        XCTAssertEqual(SearchDateResolver.label(from: from, to: to, now: now, calendar: cal), "Aug 4")
    }

    func testSingleDayThatIsTodayStillLabelsAsToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let from = cal.date(from: DateComponents(year: 2026, month: 8, day: 28))!
        let to = cal.date(byAdding: .day, value: 1, to: from)!.addingTimeInterval(-1)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 14))!
        XCTAssertEqual(SearchDateResolver.label(from: from, to: to, now: now, calendar: cal), "Today")
    }
}

/// Regression tests for the medical-bill date-of-birth bug: a patient
/// billing statement with **no transaction date printed anywhere** whose
/// guarantor date of birth (01/30/1969) was extracted as the work date,
/// flagged only as "over a year old", and saved.
///
/// Every pre-existing guard passed it, and none of them were wrong to:
/// the date parses, it isn't in the future, and — the crux — it really is
/// printed on the document, so `ReceiptDateDetector`'s presence cross-check
/// correctly found it there. The failure is one of *kind*, not presence:
/// correctly reading a date that is not a transaction date. The two fixes
/// below attack it from opposite ends.
final class NonTransactionDateTests: XCTestCase {

    /// The reported document, transcribed. Note there is no transaction
    /// date on it at all — the only date is the DOB.
    private let medicalBillText = """
        Newport-Huntington Medical Group
        Patient Billing Portal
        JANE R. DOE
        01/30/1969 • Guarantor
        Account #4471023
        Current Balance $126.15
        """

    private var posix: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return f
    }

    private func string(monthsAgo: Int) -> String {
        posix.string(from: Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())!)
    }

    private var today: String { posix.string(from: Date()) }

    // MARK: - Direction A: the absurdity tier in ExtractedReceipt.build

    func testDateOfBirthIsRejectedNotStored() {
        // The exact reported case. The old behavior stored 1969-01-30.
        let r = ExtractedReceipt.build(
            vendor: "Newport-Huntington Medical Group", rawWorkDate: "1969-01-30",
            amount: "126.15", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: medicalBillText)
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.workDate, today, "an absurd date must be discarded, not stored")
        XCTAssertTrue(r.reviewReason.contains("1969-01-30"),
                      "the reason should name the date that was thrown away")
        XCTAssertTrue(r.reviewReason.contains("years old"))
    }

    func testRejectedDateRoutesIntoTheExistingAskTheUserFlow() {
        // `ReceiptSubmitView.finishAfterSave` and `ScannedTextSubmitView`
        // both raise their date prompt by matching this exact suffix, so
        // ending the reason with it is what makes a rejected date ask the
        // user instead of silently keeping today's.
        let r = ExtractedReceipt.build(
            vendor: "Clinic", rawWorkDate: "1969-01-30", amount: "126.15",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.reviewReason.hasSuffix("defaulted to today"))
    }

    func testRejectionKeepsAnEarlierReasonAndStillEndsInTheSuffix() {
        // A missing vendor and an absurd date are independent problems; the
        // first must not be erased, and the suffix must stay last so the
        // prompt still fires.
        let r = ExtractedReceipt.build(
            vendor: "", rawWorkDate: "1969-01-30", amount: "126.15",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.reviewReason.contains("Vendor name missing"))
        XCTAssertTrue(r.reviewReason.hasSuffix("defaulted to today"))
    }

    func testTwoYearOldReceiptIsKeptNotRejected() {
        // Guards against over-aggression. Filing an old receipt is a real
        // thing people do (an amended return, a late reimbursement) — it
        // gets flagged, never thrown away.
        let old = string(monthsAgo: 24)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: old, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.workDate, old)
        XCTAssertFalse(r.reviewReason.hasSuffix("defaulted to today"))
    }

    func testNineYearOldReceiptIsStillKept() {
        // Just inside the 10-year absurdity threshold — beyond any real
        // filing need, but the line has to be drawn somewhere unambiguous,
        // and "kept and flagged" is the safe side of it.
        let old = string(monthsAgo: 9 * 12)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: old, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.workDate, old)
        XCTAssertTrue(r.needsReview)
    }

    func testElevenYearOldDateIsRejected() {
        let old = string(monthsAgo: 11 * 12)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: old, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.workDate, today)
        XCTAssertTrue(r.reviewReason.hasSuffix("defaulted to today"))
    }

    func testFifteenMonthFlagStillFires() {
        let old = string(monthsAgo: 16)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: old, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.workDate, old)
        XCTAssertTrue(r.reviewReason.contains("please confirm"))
    }

    func testRecentDateIsNeitherFlaggedNorRejected() {
        let recent = string(monthsAgo: 2)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: recent, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertFalse(r.needsReview)
        XCTAssertEqual(r.workDate, recent)
    }

    func testFutureDateBehaviorIsUnchanged() {
        let future = posix.string(from: Calendar.current.date(byAdding: .day, value: 10, to: Date())!)
        let r = ExtractedReceipt.build(
            vendor: "Cafe", rawWorkDate: future, amount: "8.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertTrue(r.needsReview)
        XCTAssertEqual(r.reviewReason, "Date is in the future")
        XCTAssertEqual(r.workDate, future, "a future date is still flagged, not discarded")
    }

    // MARK: - Proportional wording

    func testAgeWordingIsProportionalToWhatWasFound() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 28))!
        func age(_ y: Int, _ m: Int, _ d: Int) -> String {
            ExtractedReceipt.approximateAge(
                of: cal.date(from: DateComponents(year: y, month: m, day: d))!,
                asOf: now, calendar: cal)
        }
        XCTAssertEqual(age(1969, 1, 30), "57 years")
        XCTAssertEqual(age(2024, 8, 28), "2 years")
        XCTAssertEqual(age(2025, 4, 28), "16 months")
        XCTAssertEqual(age(2026, 6, 28), "2 months")
    }

    // MARK: - Direction B: label context in ReceiptDateDetector

    func testGuarantorDateOfBirthIsNotReportedAsAPrintedDate() {
        // The other half of the fix: this document has no transaction date,
        // so the honest answer is that no date is printed on it.
        XCTAssertTrue(ReceiptDateDetector.dates(in: medicalBillText).isEmpty)
    }

    func testMedicalBillResolvesToNoDatePrintedOnTheNoAIPath() {
        // Which routes the manual path into `SubmitState.confirmDate` —
        // asking the user — instead of prefilling 1969.
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: medicalBillText))
        XCTAssertEqual(ManualEntryOCRPrefill.resolveDate(in: medicalBillText), .noDatePrinted)
    }

    func testEachExcludedLabelSuppressesItsDate() {
        let labelled = [
            "DOB 01/30/1969",
            "D.O.B.: 01/30/1969",
            "Date of Birth: 01/30/1969",
            "Birth Date 01/30/1969",
            "Birthdate 01/30/1969",
            "Born 01/30/1969",
            "01/30/1969 • Guarantor",
            "Patient: Jane Doe 01/30/1969",
            "Member since 05/14/2019",
            "Due date: 09/15/2026",
            "Payment due 09/15/2026",
            "Pay by 09/15/2026",
            "Statement period 07/01/2026",
            "Billing period 07/01/2026",
            "Service period 07/01/2026",
            "Coverage period 07/01/2026",
        ]
        for line in labelled {
            XCTAssertTrue(ReceiptDateDetector.dates(in: line).isEmpty,
                          "\(line) should not be reported as a printed transaction date")
        }
    }

    func testOrdinaryReceiptWordingIsStillAccepted() {
        // The other half of the guarantee: the exclusion list must not eat
        // real transaction dates. None of these lines is labelled as
        // anything but a purchase.
        let ordinary = [
            "Order Date: 08/12/2026",
            "Sale Date: 08/12/2026",
            "Transaction Date 08/12/2026",
            "Served 08/12/2026 by Arvyn",
            "0603 00053 01304 08/12/2026 01:05 PM",
            "Reborn Coffee 08/12/2026",
            "Balance Due 08/12/2026",
        ]
        for line in ordinary {
            let dates = ReceiptDateDetector.dates(in: line)
            XCTAssertEqual(dates.count, 1, "\(line) should still yield its printed date")
            let c = Calendar.current.dateComponents([.year, .month, .day], from: dates[0])
            XCTAssertEqual([c.year, c.month, c.day], [2026, 8, 12], "\(line)")
        }
    }

    func testLabelledDateDoesNotMaskARealDateOnAnotherLine() {
        let text = """
            Patient: Jane Doe
            01/30/1969 • Guarantor
            Visit charge 08/12/2026    $126.15
            """
        let dates = ReceiptDateDetector.dates(in: text)
        XCTAssertEqual(dates.count, 1)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dates[0])
        XCTAssertEqual([c.year, c.month, c.day], [2026, 8, 12])
    }

    func testCrossCheckNoLongerCorrectsAGoodDateIntoADateOfBirth() {
        // Before the label rule, the DOB was the single "printed" date on
        // this document, so a model that got the date right would have had
        // it *overwritten* with 1969 by the auto-correct branch.
        let recent = string(monthsAgo: 1)
        let r = ExtractedReceipt.build(
            vendor: "Newport-Huntington Medical Group", rawWorkDate: recent,
            amount: "126.15", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: medicalBillText)
        XCTAssertEqual(r.workDate, recent)
        XCTAssertFalse(r.needsReview)
    }

    func testNamesNonTransactionDateIsWholeTokenMatched() {
        XCTAssertTrue(ReceiptDateDetector.namesNonTransactionDate("D.O.B. 01/30/1969"))
        XCTAssertTrue(ReceiptDateDetector.namesNonTransactionDate("01/30/1969 • Guarantor"))
        XCTAssertFalse(ReceiptDateDetector.namesNonTransactionDate("Reborn Coffee"))
        XCTAssertFalse(ReceiptDateDetector.namesNonTransactionDate("Doborn Ltd"))
        XCTAssertFalse(ReceiptDateDetector.namesNonTransactionDate("TOTAL $12.00"))
    }
}

/// Covers the amount cross-check when the image contains no amounts at all —
/// the case that used to pass silently.
///
/// Found by photographing the document-scanner screen itself: OCR read its
/// button labels ("Flash Filters Shutter") as a vendor, and the model
/// returned $142.51 — the literal example value from this app's own prompt
/// (`FoundationModelsService`'s amount `@Guide`), echoed back because there
/// was nothing to read. Almost certainly the same cause as the original
/// $142.51 failure recorded in AMOUNT_GUARDRAIL_PLAN.md.
///
/// Every fixture here uses a valid printed date, so the date guardrail can't
/// be what trips `needsReview` — the amount rule is what's under test.
final class AmountWithNoPrintedAmountsTests: XCTestCase {

    /// Long enough to clear `minimumSourceTextLengthForNoDateRejection`, i.e.
    /// to read as a document OCR genuinely processed rather than a failed
    /// pass — and containing a date, but no currency amount anywhere.
    private let screenshotOfACameraUI = """
    3:51 Yesterday 2026-03-20 Position the document in view
    Cancel Flash Filters Shutter Photos Library Recents Albums Done
    """

    func testAnAmountIsFlaggedWhenReadableTextShowsNoAmountsAtAll() {
        let receipt = ExtractedReceipt.build(
            vendor: "Flash Filters Shutter", rawWorkDate: "2026-03-20", amount: "142.51",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: screenshotOfACameraUI)

        XCTAssertTrue(receipt.needsReview,
                      "An amount returned for an image with no amounts on it must be flagged.")
        XCTAssertFalse(receipt.reviewReason.isEmpty)
    }

    func testAnAmountPrintedOnTheReceiptIsStillNotFlagged() {
        // The obvious over-correction: this must not flag every receipt whose
        // amount the detector did find.
        let receipt = ExtractedReceipt.build(
            vendor: "Monteras", rawWorkDate: "2026-03-20", amount: "14.66",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: """
            MONTERAS CAFE 3333 Bristol Street, Costa Mesa CA 92626
            2026-03-20 SUBTOTAL 13.45 SALES TAX 1.21 TOTAL $14.66 VISA
            """)

        XCTAssertFalse(receipt.needsReview, receipt.reviewReason)
    }

    func testShortOrEmptySourceTextIsNotTreatedAsAnAbsentAmount() {
        // OCR failing, or a provider that supplies no text at all, means "we
        // have nothing to check against" — not "the image had no amount".
        // Flagging these would mark every receipt from such a provider, and
        // every bad photo, for review.
        for text in ["", "blur", "TOTAL"] {
            let receipt = ExtractedReceipt.build(
                vendor: "Monteras", rawWorkDate: "2026-03-20", amount: "14.66",
                comments: "", rawVendorType: "", modelReportedLowConfidence: false,
                modelReason: "", sourceText: text)
            XCTAssertFalse(receipt.needsReview,
                           "sourceText \"\(text)\" is a failed read, not an absent amount: \(receipt.reviewReason)")
        }
    }

    func testNoSourceTextAtAllSkipsTheCrossCheck() {
        let receipt = ExtractedReceipt.build(
            vendor: "Monteras", rawWorkDate: "2026-03-20", amount: "14.66",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: nil)

        XCTAssertFalse(receipt.needsReview, receipt.reviewReason)
    }

    /// Real case: a LIFECAFE order-confirmation web page — order number,
    /// pickup time, "Receipt sent" — with no price printed anywhere. The
    /// model still returned $14.95, and it was saved with nothing more than
    /// a quiet flag: `ReceiptSubmitView` only raised its blocking
    /// `.needsAmount` prompt for the "isn't printed" reason variant, not
    /// this "no amount could be found at all" one, so a fabricated number
    /// went straight into a tax record.
    private let lifecafeOrderConfirmationText = """
    LIFECAFE
    Order #48213
    Pickup time: 5:45 PM
    Receipt sent to your email
    """

    func testLifecafeOrderConfirmationWithNoPricesFlagsTheInventedAmount() {
        XCTAssertTrue(ReceiptAmountDetector.amounts(in: lifecafeOrderConfirmationText).isEmpty,
                       "the page prints no currency-shaped text at all")

        let receipt = ExtractedReceipt.build(
            vendor: "LIFECAFE", rawWorkDate: "2026-03-20", amount: "14.95",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: lifecafeOrderConfirmationText)

        XCTAssertTrue(receipt.needsReview)
        // Matches the substring `ReceiptSubmitView.noAmountFoundMarker`
        // looks for — see that constant's comment in ReceiptSubmitView.swift
        // for why this is now the STRONGER of the two amount guardrails,
        // not a lesser one.
        XCTAssertTrue(receipt.reviewReason.contains("No amount could be found"),
                      "must carry the no-amount-found marker: \(receipt.reviewReason)")
    }
}

// MARK: - Backup copy destination labels
//
// `exportLocationLabel` names the place a user exported a backup copy to.
// The document picker confirms that a copy was written, but no public API
// says what the destination is *called*, so the label is inferred from the
// on-disk path spelling. That makes it a guess printed as fact on the
// Archive & Backup screen — worth pinning down, since the failure mode is
// telling someone their backup is somewhere it isn't.

final class BackupExportLocationTests: XCTestCase {

    func testICloudDriveIsNamedFromItsContainerSpelling() {
        // How iCloud Drive is actually spelled on disk. The user-visible
        // name ("iCloud Drive") appears nowhere in the path, which is why
        // this is matched rather than read.
        let url = URL(fileURLWithPath:
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Receipts4Tax-2026-09-09.zip")
        XCTAssertEqual(ArchiveBackupView.exportLocationLabel(for: url), "iCloud Drive")
    }

    func testICloudDriveIsStillRecognizedInsideASubfolder() {
        let url = URL(fileURLWithPath:
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2026/backup.zip")
        XCTAssertEqual(ArchiveBackupView.exportLocationLabel(for: url), "iCloud Drive")
    }

    func testAThirdPartyProviderFallsBackToItsFolderName() {
        // Dropbox, Google Drive and the rest have no spelling worth
        // special-casing, so the containing folder is the honest answer —
        // vague, but never wrong the way a guessed brand name would be.
        let url = URL(fileURLWithPath:
            "/private/var/mobile/Containers/Shared/AppGroup/ABC/File Provider Storage/Taxes/backup.zip")
        XCTAssertEqual(ArchiveBackupView.exportLocationLabel(for: url), "Taxes")
    }

    func testARootLevelDestinationFallsBackToFiles() {
        // Nothing usable to name: better a generic "Files" than an empty
        // string rendered into "Last copy saved: , Sep 9".
        XCTAssertEqual(ArchiveBackupView.exportLocationLabel(for: URL(fileURLWithPath: "/backup.zip")), "Files")
    }
}

// MARK: - Status search intents (the "duplicates" / "needs review" / "queued" bug)
//
// The Receipts search field used to have no way to express these three fixed
// app concepts at all — `QueryParseResult` only has vendor/amount/date
// fields, so a query like "duplicates" or "queued receipts" parsed to
// nothing and fell through to plain vendor-name matching, which of course
// found nothing. `ReceiptStatusQuery` recognises them deterministically
// instead, so ReceiptsView can answer with the same banner the main list
// already shows for that status. These tests pin the matcher itself, not
// the view — the important regression guard is the last one: an ordinary
// vendor search must never be mistaken for a status request.

final class ReceiptStatusQueryTests: XCTestCase {

    func testNeedsReviewMatchesItsPrimaryPhrasingAndASynonym() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "needs review"), [.needsReview])
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "flagged"), [.needsReview])
    }

    func testDuplicatesMatchesItsPrimaryPhrasingAndASynonym() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "duplicates"), [.duplicates])
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "dupes"), [.duplicates])
    }

    func testQueuedMatchesItsPrimaryPhrasingAndASynonym() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "queued"), [.queued])
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "pending"), [.queued])
    }

    // The user's own reported queries — the actual bug, not a paraphrase of it.

    func testShowMeDuplicateReceiptsIsRecognized() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "Show me duplicate receipts"), [.duplicates])
    }

    func testQueuedReceiptsIsRecognized() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "queued receipts"), [.queued])
    }

    func testNeedReviewsIsRecognized() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "need reviews"), [.needsReview])
    }

    func testAQueryNamingTwoIntentsReturnsBoth() {
        XCTAssertEqual(ReceiptStatusQuery.intents(in: "duplicates that need review"), [.duplicates, .needsReview])
    }

    // The important regression guard: an ordinary vendor search must never
    // be read as a status request, or every receipt from a vendor whose name
    // happens to contain one of these words would trigger a banner instead
    // of (or alongside) an otherwise unrelated search.
    func testOrdinaryVendorSearchesMatchNoIntent() {
        XCTAssertTrue(ReceiptStatusQuery.intents(in: "Eureka Restaurant").isEmpty)
        XCTAssertTrue(ReceiptStatusQuery.intents(in: "in-n-out").isEmpty)
    }

    func testStrippingIntentsLeavesNothingForAPureStatusQuery() {
        XCTAssertEqual(ReceiptStatusQuery.strippingIntents(from: "needs review"), "")
        XCTAssertEqual(ReceiptStatusQuery.strippingIntents(from: "queued receipts"), "receipts")
    }

    func testStrippingIntentsLeavesTheRemainderForAMixedQuery() {
        XCTAssertEqual(ReceiptStatusQuery.strippingIntents(from: "restaurants needing review"), "restaurants")
    }
}

// MARK: - Coarser date passes must not rescue a rejected specific date
//
// Adding the named-month, relative-period and bare-year passes created a
// route around the oldest guarantee in `SearchQueryDateParser`: a date the
// user typed and the calendar rejected must produce no filter at all. The
// year fragment of "02/30/2026" is still sitting in the text, so a bare-year
// pass reading it would answer an impossible date with the whole of 2026 —
// a fabricated range, arrived at by a longer route. These pin the boundary.

final class SearchDateFallbackBoundaryTests: XCTestCase {

    private func range(_ query: String, now: Date) -> (from: Date, to: Date)? {
        SearchQueryDateParser.explicitRange(in: query, now: now)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testImpossibleNumericDateIsNotRescuedByTheBareYearPass() {
        XCTAssertNil(range("receipts on 02/30/2026", now: date(2026, 8, 28)))
    }

    func testImpossibleNumericDateIsNotRescuedByARelativePhraseElsewhere() {
        // Two competing readings in one query. The typed date still wins by
        // refusing: the user named a day, and it wasn't a real one.
        XCTAssertNil(range("receipts on 02/30/2026 last month", now: date(2026, 8, 28)))
    }

    func testAValidNumericDateStillResolvesToThatDay() {
        // The guard must reject only what the calendar rejected, never a
        // date that parses cleanly.
        let resolved = range("receipts on 07/04/2026", now: date(2026, 8, 28))
        XCTAssertEqual(resolved?.from, date(2026, 7, 4))
    }

    func testABareYearStillResolvesWhenNoNumericDateWasTyped() {
        let resolved = range("receipts from 2026", now: date(2026, 8, 28))
        XCTAssertEqual(resolved?.from, date(2026, 1, 1))
    }
}
