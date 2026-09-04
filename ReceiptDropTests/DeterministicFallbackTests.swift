import XCTest
@testable import ReceiptDrop

/// Covers preferring deterministic on-device reads over the model's answer
/// when the model's is plainly unusable — for the vendor and the date only.
///
/// The principle was already in the codebase for one narrow case (a
/// parseable-but-wrong date with exactly one date printed): "deterministic
/// text beats model inference here… still flagged, so the correction is
/// visible, but the stored value is right even if the user never looks."
/// These tests cover extending it to the cases the fixture run showed
/// actually happen.
///
/// Amount is deliberately excluded and has no tests here because there is
/// nothing to test: a receipt carries many numbers, and substituting one
/// risks writing a *different* wrong figure into a tax record. It stays
/// flag-only.
final class DeterministicFallbackTests: XCTestCase {

    private let receiptText = """
    NAAN AND KABOB LLC
    416 E 1ST ST, TUSTIN, CA 92780
    09/03/2026  18:26:34
    CREDIT CARD  VISA SALE
    PRE-TIP AMT  $89.93
    """

    // MARK: - Date

    func testAPrintedDateIsUsedInsteadOfTodayWhenTheModelGivesNone() {
        // The dominant failure in the fixture run: Apple On-Device returned
        // no usable date 8 times out of 12, and every one was stored as
        // today — despite the date being right there in the OCR text.
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: receiptText)

        XCTAssertEqual(receipt.workDate, "2026-09-03")
        XCTAssertNotEqual(receipt.workDate, ExtractedReceipt.todayString())
        XCTAssertTrue(receipt.needsReview, "A recovered date is still unverified — it must stay flagged.")
    }

    func testAmbiguousDatesStillDefaultToTodayRatherThanGuessing() {
        // Two dates printed and no model answer to arbitrate between them.
        // Picking one would write a confident wrong date into a tax record.
        let twoDates = """
        SOME STORE, 100 MAIN ST
        Ordered: 01/04/2026
        Delivered: 02/09/2026
        TOTAL $42.00
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Some Store", rawWorkDate: "", amount: "42.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: twoDates)

        XCTAssertEqual(receipt.workDate, ExtractedReceipt.todayString())
        XCTAssertTrue(receipt.needsReview)
        XCTAssertTrue(receipt.reviewReason.contains("defaulted to today"),
                      "Callers raise the set-the-date prompt off that suffix: \(receipt.reviewReason)")
    }

    func testNoSourceTextStillDefaultsToToday() {
        let receipt = ExtractedReceipt.build(
            vendor: "Some Store", rawWorkDate: "", amount: "42.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: nil)

        XCTAssertEqual(receipt.workDate, ExtractedReceipt.todayString())
        XCTAssertTrue(receipt.reviewReason.contains("defaulted to today"))
    }

    // MARK: - Vendor

    func testJargonIsRecognisedAndPlainNamesAreNot() {
        for jargon in ["CRE", "Sul", "CREDIT CARD", "Visa Sale", "SUBTOTAL",
                       "Merchant Copy", "PRIME CHECKING"] {
            XCTAssertTrue(ExtractedReceipt.looksLikeReceiptJargon(jargon), jargon)
        }
        // Must be wrong in only one direction — a real business whose name
        // contains a receipt word has to survive.
        for name in ["Total Fitness", "Naan and Kabob LLC", "Eureka!",
                     "Cash Converters", "Tax Advisors Group", "IKEA"] {
            XCTAssertFalse(ExtractedReceipt.looksLikeReceiptJargon(name), name)
        }
    }

    func testAJargonVendorIsReplacedByTheDeterministicRead() {
        let receipt = ExtractedReceipt.build(
            vendor: "Sul", rawWorkDate: "2026-09-03", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: receiptText)

        XCTAssertNotEqual(receipt.vendor, "Sul")
        XCTAssertTrue(receipt.needsReview)
    }

    func testAJargonVendorIsFlaggedEvenWithNothingBetterToOffer() {
        // No usable text to recover from: the model's answer stands, because
        // blanking it would hide what was read — but it is flagged, which is
        // the part that matters.
        let receipt = ExtractedReceipt.build(
            vendor: "CRE", rawWorkDate: "2026-09-03", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: nil)

        XCTAssertEqual(receipt.vendor, "CRE")
        XCTAssertTrue(receipt.needsReview)
        XCTAssertFalse(receipt.reviewReason.isEmpty)
    }

    func testAPlausibleVendorIsLeftCompletelyAlone() {
        // The guardrail must not touch the normal case.
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob LLC", rawWorkDate: "2026-09-03", amount: "89.93",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: receiptText)

        XCTAssertEqual(receipt.vendor, "Naan and Kabob LLC")
        XCTAssertFalse(receipt.needsReview, receipt.reviewReason)
    }
}
