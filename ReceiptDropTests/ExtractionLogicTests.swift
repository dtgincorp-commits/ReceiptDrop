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

    func testNormalizeDateFallsBackToTodayForGarbage() {
        let today = DateFormatter.posixDay.string(from: Date())
        XCTAssertEqual(ClaudeService.normalizeDate("14/03/2026"), today)
        XCTAssertEqual(ClaudeService.normalizeDate(""), today)
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
