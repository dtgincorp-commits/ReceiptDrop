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
}

private extension DateFormatter {
    static let posixDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return f
    }()
}
