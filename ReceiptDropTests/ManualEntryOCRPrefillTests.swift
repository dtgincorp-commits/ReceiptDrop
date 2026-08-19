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
        // Order date vs. some other past-dated line (e.g. a loyalty-program
        // enrollment date) — both parse, both are safely in the past, and
        // neither sits next to a clock time, so neither of `likelyReceiptDate`'s
        // two disambiguation rules can apply. Picking either silently risks
        // writing the wrong one into a tax record, so this must stay nil
        // rather than guess.
        //
        // Deliberately two bare, unambiguous *past* dates, fixed years in
        // the past rather than relative to "today" — a future-dated one
        // here (e.g. a "valid through" date after the current test-run
        // date) would now get dropped by the future-date rejection rule
        // before ambiguity is even reached, which is exactly what that rule
        // is *supposed* to do and would defeat the point of this test. Also
        // deliberately two bare dates rather than phrases like "valid
        // through 2020-09-01" — NSDataDetector (which `ReceiptDateDetector`
        // is built on) treats "through <date>" as an *implied date range
        // starting today*, so `match.date` there comes back as today's
        // date, not the printed one. That's a real quirk of the underlying
        // detector, not something this test is trying to exercise —
        // verified directly against NSDataDetector before landing this
        // test, so it isn't accidentally asserting on today's date matching
        // by coincidence.
        let text = """
        08/12/2020
        Reward enrolled 09/01/2020
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

    // MARK: - Home Depot thermal receipt (real-device regression)

    /// Layout-joined text as `VisionLayoutService.recognizeRowsViaRawOCR` +
    /// `layoutString` would render it — labels paired with their trailing
    /// amount on the same line, unlike the flat `VisionOCRService.recognizeText`
    /// join that put "TOTAL" and "$145.17" on separate lines and caused all
    /// three fields (vendor, amount, date) to come back wrong on real-device
    /// testing. See `ReceiptSubmitView.prefillManualFieldsFromOCR`.
    private static let homeDepotReceiptText = """
    How doers get more done
    2782 EL CAMINO REAL, TUSTIN 92782 PH(714) 838-9200
    ALEXANDER_S_PULA@HOMEDEPOT.COM
    0603  00053  01304   07/09/26  01:05 PM
    SALE CASHIER ARVYN
    VERSABOND BONDING MORTAR-WHITE 50LB      134.73
    SUBTOTAL     134.73
    SALES TAX     10.44
    TOTAL       $145.17
    XXXXXXXXXXXX4841 HOME DEPOT   USD$ 145.17
    PRO XTRA MEMBER STATEMENT
    2026 PRO XTRA SPEND 07/08:   $1,040.81
    POLICY ID  DAYS  POLICY EXPIRES ON
      A    11   365      07/09/2027
    """

    func testHomeDepotReceiptAmountIsGrandTotalNotLoyaltySpend() {
        // The bug: on flat (non-layout) OCR text, "TOTAL" and "$145.17"
        // landed on separate lines, BillTotalsParser found no labeled total,
        // and the "largest amount" fallback picked up the bigger
        // "$1,040.81" Pro Xtra year-to-date figure instead. On layout-joined
        // text (this test), the label and its amount share a line, so the
        // labeled path finds the real total directly.
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: Self.homeDepotReceiptText), "145.17")
    }

    func testGrandTotalFallbackExcludesLoyaltyStatementLineWhenNoLabelFound() {
        // Even when no "Total"/"Subtotal"/"Tax" label survives OCR at all
        // (so the fallback "largest amount" path is the only option left),
        // a loyalty/statement line's bigger figure must not win just because
        // it's numerically larger than every real line-item price.
        let text = """
        VERSABOND BONDING MORTAR-WHITE 50LB      134.73
        2026 PRO XTRA SPEND 07/08:   $1,040.81
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "134.73")
    }

    func testGrandTotalFallbackStillCountsBalanceDueAsATotal() {
        // "Balance" is a statement-context trigger word, but "Balance Due"
        // specifically means "the amount owed" and must still be picked up
        // by the fallback rather than excluded alongside genuine loyalty/
        // rewards-balance lines.
        let text = """
        Item                      50.00
        Rewards Balance          200.00
        Balance Due                50.00
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyGrandTotal(in: text), "50.00")
    }

    func testHomeDepotReceiptDateResolvesToTransactionDateNotFutureExpiry() {
        // Three dates print on this receipt: the 07/09/26 transaction date,
        // "07/08" inside the Pro Xtra spend line, and the 07/09/2027 policy
        // expiry. Before the fix, `likelyReceiptDate` returned nil for any
        // receipt with more than one printed date; now it should resolve to
        // the transaction date specifically — future-date rejection removes
        // the 2027 expiry, and time-of-day adjacency prefers 07/09/26 (which
        // sits next to "01:05 PM") over the bare "07/08" spend-summary date.
        let date = ManualEntryOCRPrefill.likelyReceiptDate(in: Self.homeDepotReceiptText)
        XCTAssertNotNil(date)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 7)
        XCTAssertEqual(c.day, 9)
    }

    func testReceiptDateRejectsSoleFutureDate() {
        let futureYear = Calendar.current.component(.year, from: Date()) + 1
        let text = "Policy expires on \(futureYear)-01-01"
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: text))
    }

    func testReceiptDatePicksPastDateOverFutureDateWithNoTimeNeeded() {
        // Rule 1 alone should resolve this: after dropping the future date,
        // exactly one candidate remains, so rule 2 (time-of-day adjacency)
        // never even needs to run.
        let futureYear = Calendar.current.component(.year, from: Date()) + 1
        let text = """
        08/12/2026
        Policy expires on \(futureYear)-01-01
        """
        let date = ManualEntryOCRPrefill.likelyReceiptDate(in: text)
        XCTAssertNotNil(date)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 12)
    }

    func testReceiptDateStillNilWhenTwoPastDatesAndNeitherHasATime() {
        // Both rules apply and neither disambiguates — this must stay nil
        // rather than guess between an order date and some other past date.
        let text = """
        08/12/2026
        Reward earned 08/01/2026
        Total                   42.10
        """
        XCTAssertNil(ManualEntryOCRPrefill.likelyReceiptDate(in: text))
    }

    func testVendorPrefersEmailDomainOverMisleadingSloganLine() {
        // "How doers get more done" clears every existing line-level
        // disqualifier (real letters, not digit-heavy, no boilerplate
        // prefix) and would otherwise be picked as the vendor before the
        // real store line is ever reached. The printed cashier email's
        // domain is a much stronger signal and should win instead.
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: Self.homeDepotReceiptText), "Homedepot")
    }

    func testVendorDomainIgnoresPersonalEmailProviders() {
        // A customer's own personal email sometimes appears in loyalty
        // context on a receipt — "Gmail" must never be prefilled as the
        // vendor. Falls through to the line heuristic instead.
        let text = """
        Ace Hardware
        Loyalty account: shopper123@gmail.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Ace Hardware")
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
