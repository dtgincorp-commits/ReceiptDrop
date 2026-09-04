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

    // MARK: - Vendor position

    /// A real restaurant slip: business name at the top, staff and totals
    /// far below. Long enough to clear the minimum-text gate.
    private let fullSlip = """
    NAAN AND KABOB LLC
    416 E 1ST ST
    TUSTIN, CA 92780
    09/03/2026  18:26:34
    MID: XXXXXXXXXXXX023
    CREDIT CARD
    VISA SALE
    Manager: THU
    Sub-total  82.11
    Tax  7.82
    PRE-TIP AMT  $89.93
    TOTAL AMOUNT
    Gratuity Guidelines 15% = $13.48
    CREDIT VOUCHER
    """

    func testANameFromTheTopIsAccepted() {
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("NAAN AND KABOB LLC", of: fullSlip))
        // The tidied-up form the model usually returns still matches, since
        // comparison is on the first significant word.
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("Naan and Kabob", of: fullSlip))
    }

    func testTextFromLowerDownIsRejected() {
        // Wrong vendors from four scans of one photo. All nouns, which is
        // why a part-of-speech test would have passed every one of them.
        for wrong in ["Manager", "Sub-total", "Gratuity"] {
            XCTAssertFalse(ExtractedReceipt.appearsNearTheTop(wrong, of: fullSlip), wrong)
        }
    }

    func testThePositionalCheckAndTheJargonListCoverDifferentGround() {
        // "CREDIT VOUCHER" is printed at the FOOT of the slip, but the words
        // "CREDIT CARD" appear in the header block — so position alone
        // accepts it. The jargon list is what catches it, and this is why
        // both checks exist rather than one.
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("CREDIT VOUCHER", of: fullSlip))
        XCTAssertTrue(ExtractedReceipt.looksLikeReceiptJargon("CREDIT VOUCHER"))

        let receipt = ExtractedReceipt.build(
            vendor: "CREDIT VOUCHER", rawWorkDate: "2026-09-03", amount: "89.93",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: fullSlip)
        XCTAssertTrue(receipt.needsReview)
    }

    func testAOneWordDictionaryBrandAtTheTopIsAccepted() {
        // The case that rules out "is it a proper noun?" as the test: Apple,
        // Target, Shell and Chase are real vendors and ordinary words. They
        // pass because of where they are printed, not what they mean.
        let appleStore = """
        Apple
        The Grove, 189 The Grove Drive
        Los Angeles, CA 90036
        09/03/2026
        Order Number W1234567
        Subtotal 999.00
        Sales Tax 89.91
        Manager approved
        TOTAL 1088.91
        """
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("Apple", of: appleStore))
        XCTAssertFalse(ExtractedReceipt.appearsNearTheTop("Manager", of: appleStore))
    }

    func testShortOrMissingTextRaisesNoObjection() {
        // Same rule as every other cross-check here: with too little text to
        // judge, say nothing rather than flag everything.
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("Anything", of: nil))
        XCTAssertTrue(ExtractedReceipt.appearsNearTheTop("Anything", of: "blurry"))
    }

    func testAVendorFromLowerDownIsFlaggedEndToEnd() {
        let receipt = ExtractedReceipt.build(
            vendor: "Manager", rawWorkDate: "2026-09-03", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: fullSlip)

        XCTAssertTrue(receipt.needsReview)
        XCTAssertNotEqual(receipt.vendor, "Manager",
                          "The deterministic read from the top of the receipt should win.")
    }

    // MARK: - Provider capability

    func testOnlyAppleOnDeviceIsTextOnly() {
        // The full-image retry in SubmissionPipeline.extractWithFallback is
        // meaningless against a provider that never looks at the image, and
        // keeping its result discarded a perfectly good first attempt.
        XCTAssertFalse(ExtractionProvider.appleOnDevice.seesTheImage)
        for provider in ExtractionProvider.allCases where provider != .appleOnDevice {
            XCTAssertTrue(provider.seesTheImage, provider.displayName)
        }
    }

    // MARK: - Vendor

    func testJargonIsRecognisedAndPlainNamesAreNot() {
        for jargon in ["CRE", "Sul", "CREDIT CARD", "Visa Sale", "SUBTOTAL",
                       "Merchant Copy", "PRIME CHECKING", "Manager", "Server",
                       "Table", "Check"] {
            XCTAssertTrue(ExtractedReceipt.looksLikeReceiptJargon(jargon), jargon)
        }
        // Must be wrong in only one direction — a real business whose name
        // contains a receipt word has to survive.
        for name in ["Total Fitness", "Naan and Kabob LLC", "Eureka!",
                     "Cash Converters", "Tax Advisors Group", "IKEA",
                     "Manager's Special Deli", "The Bar Method",
                     "Checkers Drive-In"] {
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
