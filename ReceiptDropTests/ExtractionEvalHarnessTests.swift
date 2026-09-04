import XCTest
@testable import ReceiptDrop

/// Covers the eval's own scoring. Worth testing carefully: a scorer that is
/// too strict makes every provider look bad, and one that is too loose makes
/// them all look fine — either way the eval stops being able to answer the
/// question it exists for.
final class ExtractionEvalHarnessTests: XCTestCase {

    // MARK: - Ground truth parsing

    func testParsesARealLogRow() {
        let csv = """
        Contractor_or_Vendor_Name,Work_Date,Amount,Comments,Receipt_File,Scanned_Date
        Thai Favorite Cuisine,2026-07-15,79.15,Food was yum,DTG_2026-07-15_203001.jpg,2026-07-15
        """
        let rows = ExtractionEvalHarness.groundTruth(fromCSV: csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].vendor, "Thai Favorite Cuisine")
        XCTAssertEqual(rows[0].amount, "79.15")
        XCTAssertEqual(rows[0].receiptFile, "DTG_2026-07-15_203001.jpg")
    }

    func testAQuotedCommentContainingCommasDoesNotShiftColumns() {
        // Real row from DTG_log.csv. Split naively on commas and Receipt_File
        // becomes "protein bowl with steak" — every fixture then fails to
        // load, and the eval silently scores nothing.
        let csv = """
        Contractor_or_Vendor_Name,Work_Date,Amount,Comments,Receipt_File,Scanned_Date
        Eureka!,2026-07-16,81.13,"Rotating beer, protein bowl with steak, poke stack",DTG_2026-07-16_203604.jpg,2026-07-16
        """
        let rows = ExtractionEvalHarness.groundTruth(fromCSV: csv)
        XCTAssertEqual(rows.first?.receiptFile, "DTG_2026-07-16_203604.jpg")
        XCTAssertEqual(rows.first?.amount, "81.13")
    }

    // MARK: - Vendor matching

    func testVendorMatchIgnoresCasePunctuationAndCompanySuffix() {
        // Formatting differences are not reading errors. Scoring them as
        // wrong would measure the log's typing conventions, not the model.
        XCTAssertTrue(ExtractionEvalHarness.vendorMatches(expected: "Eureka!", got: "EUREKA"))
        XCTAssertTrue(ExtractionEvalHarness.vendorMatches(
            expected: "NAAN AND KABOB LLC", got: "Naan and Kabob"))
        XCTAssertTrue(ExtractionEvalHarness.vendorMatches(
            expected: "Thai Favorite Cuisine", got: "thai favorite cuisine"))
    }

    func testTheActualFailuresStillCountAsWrong() {
        // The whole point of the eval: these are the answers Apple
        // On-Device gave for the NAAN AND KABOB card slip.
        XCTAssertFalse(ExtractionEvalHarness.vendorMatches(expected: "NAAN AND KABOB LLC", got: "Sul"))
        XCTAssertFalse(ExtractionEvalHarness.vendorMatches(expected: "NAAN AND KABOB LLC", got: "CRE"))
        XCTAssertFalse(ExtractionEvalHarness.vendorMatches(expected: "NAAN AND KABOB LLC", got: ""))
    }

    func testAShortFragmentCannotPassByContainment() {
        // "co" normalizes away as a suffix, but a two-letter fragment like
        // "an" is inside "Naan and Kabob" — containment alone would score it
        // correct, which would hide exactly the failure mode being measured.
        XCTAssertFalse(ExtractionEvalHarness.vendorMatches(expected: "Naan and Kabob", got: "an"))
    }

    // MARK: - Amount matching

    func testAmountMatchIsNumericNotTextual() {
        XCTAssertTrue(ExtractionEvalHarness.amountMatches(expected: "89.93", got: "$89.93"))
        XCTAssertTrue(ExtractionEvalHarness.amountMatches(expected: "200.00", got: "200"))
        XCTAssertTrue(ExtractionEvalHarness.amountMatches(expected: "46.30", got: "46.3"))
    }

    func testTheGratuitySuggestionScoresWrong() {
        XCTAssertFalse(ExtractionEvalHarness.amountMatches(expected: "89.93", got: "13.48"))
        XCTAssertFalse(ExtractionEvalHarness.amountMatches(expected: "89.93", got: "134.48"))
    }

    func testAnUnparseableAmountIsWrongRatherThanCrashing() {
        XCTAssertFalse(ExtractionEvalHarness.amountMatches(expected: "89.93", got: ""))
        XCTAssertFalse(ExtractionEvalHarness.amountMatches(expected: "89.93", got: "n/a"))
    }

    // MARK: - Summary

    func testSummaryCountsWrongAndFlaggedSeparatelyFromWrong() {
        // This pair is the guardrails' own score: a wrong answer the app
        // flagged is a much smaller problem than one that sailed through.
        let truth = ExtractionEvalHarness.GroundTruth(
            receiptFile: "a.jpg", vendor: "Naan and Kabob", workDate: "2026-09-03", amount: "89.93")

        let wrongAndFlagged = ExtractionEvalHarness.score(
            truth: truth,
            extracted: ExtractedReceipt.build(
                vendor: "Sul", rawWorkDate: "2026-09-03", amount: "13.48", comments: "",
                rawVendorType: "", modelReportedLowConfidence: true, modelReason: "unclear total"),
            seconds: 1)
        let wrongAndSilent = ExtractionEvalHarness.score(
            truth: truth,
            extracted: ExtractedReceipt.build(
                vendor: "Sul", rawWorkDate: "2026-09-03", amount: "13.48", comments: "",
                rawVendorType: "", modelReportedLowConfidence: false, modelReason: ""),
            seconds: 1)

        let summary = ExtractionEvalHarness.Summary(results: [wrongAndFlagged, wrongAndSilent])
        XCTAssertEqual(summary.wrongTotal, 2)
        XCTAssertEqual(summary.wrongAndFlagged, 1)
        XCTAssertEqual(summary.vendorCorrect, 0)
    }
}
