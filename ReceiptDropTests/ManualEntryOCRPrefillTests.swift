import XCTest
@testable import ReceiptDrop

/// Tests for `ManualEntryOCRPrefill` — the deterministic guesses that fill
/// in the manual-entry vendor/amount/date fields on `ReceiptSubmitView`
/// when no AI provider is configured. These run against realistic OCR-shaped
/// text (multi-line, occasional recognition noise) rather than hand-crafted
/// single tokens, matching `ExtractionLogicTests`.
final class ManualEntryOCRPrefillTests: XCTestCase {

    // MARK: - Amount: likelyGrandTotal

    func testGrandTotalPrefersLabeledTotalOverLargerLineItem() {
        // The steak is printed larger than the actual total (tip not yet
        // added) — picking "largest number on the page" would be wrong here;
        // the labeled Total line must win.
        let text = """
        THE STEAKHOUSE
        123 Main St

        Ribeye Steak            89.00
        House Salad              9.50

        Subtotal                98.50
        Tax                      8.62
        Total                   107.12
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "107.12")
    }

    func testGrandTotalUsesLastLabeledTotalLineWhenSeveralPrinted() {
        // "Total" appears once as a subtotal-ish label further up (rare but
        // happens on some receipt layouts) and again as the real bottom
        // line — BillTotalsParser's "last one wins" convention should carry
        // through here.
        let text = """
        Item A                  10.00
        Item B                  10.00
        Total                   20.00
        Tip                      4.00
        Total                   24.00
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "24.00")
    }

    func testGrandTotalFallsBackToLargestAmountWhenNoLabelFound() {
        // No "Total"/"Amount Due"/etc label at all (OCR dropped it, or the
        // receipt just doesn't print one) — falls back to the largest
        // currency-shaped figure on the page.
        let text = """
        COFFEE SHOP
        Latte                    5.25
        Muffin                   3.75
        $9.00
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "9.00")
    }

    func testGrandTotalNilWhenNothingLooksLikeMoney() {
        let text = "Just some receipt-shaped text with no numbers at all."
        XCTAssertNil(ManualEntryOCRPrefill.likelyGrandTotal(in: text))
    }

    // MARK: - Date: likelyReceiptDate

    func testReceiptDatePrefilledWhenExactlyOneDatePrinted() {
        let text = """
        HARDWARE STORE
        08/12/2026
        Lumber                  42.10
        Total                   42.10
        """
        let date = ManualEntryOCRPrefill.likelyReceiptDate(in: text)
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 12)
    }

    func testReceiptDateNilWhenAmbiguousBetweenMultipleDates() {
        // Order date vs. a "valid through" / promo date — both parse, and
        // picking either silently risks writing the wrong one into a tax
        // record, so this must stay nil rather than guess.
        //
        // Deliberately two bare, unambiguous dates rather than phrases like
        // "valid through 09/01/2026" — NSDataDetector (which
        // `ReceiptDateDetector` is built on) treats "through <date>" as an
        // *implied date range starting today*, so `match.date` there comes
        // back as today's date, not the printed one. That's a real quirk of
        // the underlying detector, not something this test is trying to
        // exercise — verified directly against NSDataDetector before
        // landing this test, so it isn't accidentally asserting on today's
        // date matching by coincidence.
        let text = """
        08/12/2026
        Reward expires 09/01/2026
        Total                   42.10
        """
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: text))
    }

    func testReceiptDateNilWhenNoDatePrinted() {
        let text = "GAS STATION\nUnleaded  40.00\nTotal  40.00"
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: text))
    }

    func testReceiptDateIgnoresBareTimeOfDayLine() {
        // A bare clock time ("Time  2:30 PM") is detected as "today" by
        // NSDataDetector — ReceiptDateDetector already filters that out, and
        // this should inherit that filtering rather than treating "today" as
        // a printed date.
        let text = "CAFE\nTime  2:30 PM\nTotal  5.00"
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: text))
    }

    // MARK: - Vendor: likelyVendorLine

    func testVendorPicksFirstPlausibleLine() {
        let text = """
        Home Depot
        123 Main St, Springfield IL 62701
        (217) 555-0100

        Lumber                  42.10
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Home Depot")
    }

    func testVendorSkipsLeadingBoilerplateAndAddressLines() {
        let text = """
        RECEIPT
        123 Main St, Springfield IL 62701
        Trader Joe's
        Bananas                  1.99
        Total                    1.99
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Trader Joe's")
    }

    func testVendorSkipsDateAndAmountOnlyLines() {
        let text = """
        08/12/2026
        $42.10
        Ace Hardware
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Ace Hardware")
    }

    func testVendorNilWhenNothingPlausibleFound() {
        // Every line is either boilerplate, numeric, or too short — no line
        // should be confidently accepted as a vendor name.
        let text = """
        RECEIPT
        123 Main St
        (217) 555-0100
        08/12/2026
        $42.10
        """
        XCTAssertNil(ManualEntryOCRPrefill.likelyVendorLine(in: text))
    }
}

/// Regression tests for the range-wording filter in `ReceiptDateDetector`.
///
/// These sit alongside the prefill tests because the no-AI prefill is where
/// the bug was first seen, but the detector is shared with the AI pipeline's
/// cross-check — where reporting today as "printed on the receipt" is worse,
/// since that check exists specifically to catch a model inventing a date.
final class ReceiptDateDetectorRangeWordingTests: XCTestCase {

    func testCouponValidThroughIsNotReadAsAPrintedDate() {
        // NSDataDetector reads "through <date>" as a span starting now, so
        // its `.date` is today with a non-zero duration. Nothing on this
        // receipt is printed with today's date, so nothing should be found.
        let dates = ReceiptDateDetector.dates(in: "Coupon valid through 09/01/2026")
        XCTAssertTrue(dates.isEmpty)
    }

    func testOfferGoodUntilIsNotReadAsAPrintedDate() {
        let dates = ReceiptDateDetector.dates(in: "Offer good until 09/01/2026")
        XCTAssertTrue(dates.isEmpty)
    }

    func testExpiresWordingStillReadsTheDateItPrints() {
        // "Expires" carries no range sense, so this stays a plain date and
        // must survive the filter — the guard keys on duration, not on any
        // list of words, and this is what stops it over-reaching.
        let dates = ReceiptDateDetector.dates(in: "Expires 09/01/2026")
        XCTAssertEqual(dates.count, 1)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: dates[0])
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 9)
        XCTAssertEqual(c.day, 1)
    }

    func testRangeWordingDoesNotMaskARealDateElsewhere() {
        let dates = ReceiptDateDetector.dates(in: """
        Purchase Date: 08/12/2026
        Coupon valid through 09/01/2026
        """)
        XCTAssertEqual(dates.count, 1)
        let c = Calendar.current.dateComponents([.month, .day], from: dates[0])
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 12)
    }
}
