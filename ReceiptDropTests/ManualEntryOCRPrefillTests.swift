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

    func testVendorFallsBackToBareDomainWhenAtSignIsMangled() {
        // Real-device OCR on a Home Depot receipt read
        // "ALEXANDER_S_PULA@HOMEDEPOT.COM" as "PULACHOMEDEPÖT.COM" — the
        // "@" vanished entirely, so the email-based match finds nothing.
        // The same receipt still prints "homedepot.com" in the clear a few
        // lines down ("Learn more at homedepot.com/credit"); the
        // bare-domain fallback must still find it rather than falling all
        // the way through to the line heuristic (which would otherwise
        // grab whatever plausible-looking line comes first).
        let text = """
        ALEXANDER S_PULACHOMEDEPÖT.COM
        0603  00053  01304   07/09/26  01:05 PM
        SUBTOTAL     134.73
        TOTAL       $145.17
        Learn more at homedepot.com/credit
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Homedepot")
    }

    func testVendorBareDomainFallbackStillIgnoresPersonalEmailProviders() {
        // A bare "gmail.com" printed without an "@" (e.g. a mangled
        // customer-email loyalty line) must be excluded from the fallback
        // the same way the "@"-based path excludes it.
        let text = """
        Ace Hardware
        Loyalty account gmail.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Ace Hardware")
    }

    func testVendorBareDomainFallbackIgnoresPaymentProcessorDomains() {
        // A card network or payment processor often prints its own domain
        // on the receipt footer without being the merchant that sold the
        // goods — this must not be picked up as the vendor.
        let text = """
        Ace Hardware
        123 Main St
        Powered by squareup.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Ace Hardware")
    }

    func testVendorPrefersEmailMatchOverBareDomainWhenBothPresent() {
        // The "@"-based match is the stronger signal and must win even
        // when a bare domain for a different, unrelated site also appears
        // on the receipt.
        let text = """
        cashier@westcoasthardware.com
        Learn more at unrelatedadvertiser.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Westcoasthardware")
    }

    func testVendorBareDomainFallbackPrefersEarlierOccurrenceOverFooter() {
        // When no "@" survives OCR at all, and multiple distinct bare
        // domains are printed, the fallback should prefer the one that
        // appears earlier (closer to the merchant's own header) over one
        // buried further down in footer/marketing copy. Neither domain here
        // is a suffix of the other and both appear exactly once, so this
        // exercises the plain reading-order tiebreak, unaffected by the
        // suffix/frequency rules added for the fused-username bug below.
        let text = """
        Visit westcoasthardware.com for hours
        Financing details at somebank.com/apply
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Westcoasthardware")
    }

    // MARK: - Vendor: bare-domain fallback, fused-username OCR artifact
    // (real-device evidence — low-light photo of the same Home Depot receipt
    // that motivated `testVendorFallsBackToBareDomainWhenAtSignIsMangled`
    // above; see `50e93d1` and the bug report this fix responds to)

    func testVendorBareDomainFallbackResolvesFusedUsernameToTheShorterRealDomain() {
        // The exact real-world failure: low light made OCR read the "@" in
        // "ALEXANDER_S_PULA@HOMEDEPOT.COM" as an "S" instead of dropping it,
        // fusing the username onto the domain into "PULASHOMEDEPOT.COM" —
        // a perfectly valid-looking domain that sits above the clean
        // "homedepot.com" printed a few lines down in the footer. Taking
        // "the first bare domain in reading order" (the pre-fix rule)
        // confidently returns "Pulashomedepot". Since "homedepot" is a
        // proper suffix of "pulashomedepot" and both are actually printed
        // on this receipt, the suffix rule must recognize the longer one as
        // the fusion artifact and resolve to the real, shorter domain
        // instead.
        let text = """
        PULASHOMEDEPOT.COM
        0603  00053  01304   07/09/26  01:05 PM
        SUBTOTAL     134.73
        TOTAL       $145.17
        Learn more at homedepot.com/credit
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Homedepot")
    }

    func testVendorBareDomainFallbackGoodLightVariantStillResolvesToHomedepot() {
        // Regression check for the good-light capture of the same receipt:
        // OCR here reads the "@" as "Ö" ("PULACHOMEDEPÖT.COM"), which
        // contains a non-ASCII-letter character the bare-domain regex
        // (`[A-Za-z0-9-]`) can't match at all, so it never becomes a
        // candidate in the first place — only the clean "homedepot.com"
        // footer mention ever enters the candidate list, and the suffix/
        // frequency logic added for the low-light case has nothing to do.
        // This already worked before this fix; pinned here so the new
        // multi-candidate logic doesn't regress it.
        let text = """
        ALEXANDER S_PULACHOMEDEPÖT.COM
        0603  00053  01304   07/09/26  01:05 PM
        SUBTOTAL     134.73
        TOTAL       $145.17
        Learn more at homedepot.com/credit
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Homedepot")
    }

    func testVendorEmailMatchStillWinsOutrightOverAFusedBareDomainElsewhere() {
        // When a literal "@" survives OCR and parses cleanly, that path
        // returns before the bare-domain fallback (and its suffix/frequency
        // disambiguation) ever runs at all — the "@" match stays the
        // highest-confidence signal regardless of what else is printed.
        let text = """
        alexander_s_pula@homedepot.com
        0603  00053  01304   07/09/26  01:05 PM
        TOTAL       $145.17
        Learn more at homedepot.com/credit
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Homedepot")
    }

    func testVendorBareDomainFallbackDoesNotTruncateALoneFusedLookingDomain() {
        // The suffix rule only fires when a shorter candidate is actually
        // corroborated by a second, independent match in the text — it must
        // never start stripping a suspected prefix off a single domain that
        // appears alone, since that risks mangling a real (if unlucky)
        // brand name that happens to end in a shorter, more common word.
        // With nothing else printed, "pulashomedepot.com" is taken at face
        // value, same as any other single bare-domain match.
        let text = """
        PULASHOMEDEPOT.COM
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Pulashomedepot")
    }

    func testVendorBareDomainFallbackExcludesPersonalEmailProviderEvenWhenItRepeatsMoreOften() {
        // The personal-email-provider exclusion is applied per candidate
        // before the frequency comparison ever runs — an excluded domain
        // must never win purely because it happens to be printed more
        // often than the real (excluded-list-clear) merchant domain.
        let text = """
        Ace Hardware
        Loyalty account gmail.com
        Newsletter signup at gmail.com
        Learn more at acehardware.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Acehardware")
    }

    func testVendorBareDomainFallbackExcludesPaymentProcessorEvenWhenItRepeatsMoreOften() {
        // Same guarantee for the payment-processor exclusion list — being
        // printed on every receipt line (surcharge notice, "powered by"
        // footer, card-network branding) must never be enough to outrank
        // the real merchant's own, less-frequently-printed domain.
        let text = """
        Ace Hardware
        Powered by squareup.com
        Visit squareup.com for merchant details
        Learn more at acehardware.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Acehardware")
    }

    func testVendorBareDomainFallbackFrequencyBreaksTieWhenNeitherIsASuffixOfTheOther() {
        // Frequency is the secondary signal this fix adds: when two
        // unrelated (non-suffix) domains are both printed and neither the
        // suffix rule nor plain reading order alone would obviously be
        // "more correct," a domain repeated across the receipt (header and
        // footer, as a real merchant's own domain often is) should win over
        // a domain that only appears once, even though the one-off domain
        // is printed first.
        let text = """
        Financing details at somebank.com/apply
        Visit westcoasthardware.com for hours
        Thanks for shopping at westcoasthardware.com
        Total                   42.10
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "Westcoasthardware")
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

/// Tests for the numeric-date regex pass in `ReceiptDateDetector`, added to
/// cover the real `NSDataDetector` blind spots found on a real Home Depot
/// receipt: a receipt/reference number immediately before a date with a
/// single space between them, and the word "Order" immediately before a
/// date. See the type-level doc comment on `ReceiptDateDetector` for the
/// standalone-script verification behind these.
final class ReceiptDateDetectorNumericPassTests: XCTestCase {

    private func day(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    func testSingleSpaceBeforeAYearLikeNumberNoLongerKillsTheMatch() {
        // NSDataDetector reads "1077 08/19/26" as one malformed expression
        // (1077 parses as a plausible year) and drops the whole line —
        // verified directly against NSDataDetector before landing this fix.
        // Multiple spaces ("1077    08/19/26") happened to dodge this, which
        // is exactly why this broke silently: `VisionLayoutService
        // .layoutString` used to emit multiple spaces and now emits one.
        let dates = ReceiptDateDetector.dates(in: "1077 08/19/26 11:55 AM")
        XCTAssertEqual(dates.count, 1)
        let c = day(dates[0])
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 19)
    }

    func testOrderDateLabelNoLongerKillsTheMatch() {
        // "Order Date: 08/12/2026" returns zero NSDataDetector matches
        // (verified directly), while "Sale Date: 08/12/2026" returns one —
        // an inconsistency in NSDataDetector's own word list, not anything
        // about the date itself. The regex pass doesn't care what word
        // comes before the digits.
        let dates = ReceiptDateDetector.dates(in: "Order Date: 08/12/2026")
        XCTAssertEqual(dates.count, 1)
        let c = day(dates[0])
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 12)
    }

    func testRejectsDigitsInsideAReceiptNumberBlock() {
        // "1077 61 46161 08/19/2026 1700" is real text from the receipt:
        // a receipt number, a register number, a transaction number, the
        // real date, and a 24-hour time — none of the surrounding numeric
        // noise should itself be read as a date, only the actual date.
        let dates = ReceiptDateDetector.dates(in: "1077 61 46161 08/19/2026 1700")
        XCTAssertEqual(dates.count, 1)
        let c = day(dates[0])
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 19)
    }

    func testRejectsAuthCodeShapedAsASingleSlashNumberPair() {
        // Only one separator in the whole string — can never satisfy the
        // two-separator D/M/Y shape the regex requires.
        let dates = ReceiptDateDetector.dates(in: "AUTH CODE 064152/5612915")
        XCTAssertTrue(dates.isEmpty)
    }

    func testRejectsDashedReferenceNumberShapedLikeADate() {
        // "0000" and "999" can't fit the 1-2 digit day/month groups the
        // regex requires, at any alignment within the string.
        let dates = ReceiptDateDetector.dates(in: "0000-999-735")
        XCTAssertTrue(dates.isEmpty)
    }

    func testTwoDigitYearNeverReadsAsFuture() {
        // "26" today (2026) must read as 2026, not row back to 1926 — the
        // century rule always prefers the candidate century that keeps the
        // year <= the current year, and 2026 already satisfies that.
        let dates = ReceiptDateDetector.dates(in: "08/19/26")
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(day(dates[0]).year, 2026)
    }

    func testAmbiguousDayMonthOrderDefaultsToUSConvention() {
        // Both readings (Aug 5 vs. May 8) are valid calendar dates, so this
        // is a genuinely ambiguous case — resolved via the app's existing
        // US M/D default (see `ManualEntryOCRPrefillTests`'s 08/12/2026).
        let dates = ReceiptDateDetector.dates(in: "05/08/2026")
        XCTAssertEqual(dates.count, 1)
        let c = day(dates[0])
        XCTAssertEqual(c.month, 5)
        XCTAssertEqual(c.day, 8)
    }

    func testUnambiguousDayFirstOrderingIsNotForcedIntoUSConvention() {
        // 13 can't be a month, so this can only be D/M — May 13, not a
        // nonexistent "13th month".
        let dates = ReceiptDateDetector.dates(in: "13/05/2026")
        XCTAssertEqual(dates.count, 1)
        let c = day(dates[0])
        XCTAssertEqual(c.month, 5)
        XCTAssertEqual(c.day, 13)
    }

    func testBothPartsOver12IsRejectedRatherThanGuessed() {
        // Neither ordering is a valid date — 13 and 14 can't both be
        // months, and this shouldn't be misread as any date at all.
        let dates = ReceiptDateDetector.dates(in: "13/14/2026")
        XCTAssertTrue(dates.isEmpty)
    }

    func testDashAndDotSeparatorsAreRecognized() {
        let dashDates = ReceiptDateDetector.dates(in: "08-19-2026")
        XCTAssertEqual(dashDates.count, 1)
        let dotDates = ReceiptDateDetector.dates(in: "08.19.2026")
        XCTAssertEqual(dotDates.count, 1)
    }

    func testMixedSeparatorsDoNotMatch() {
        // The two separators must match (`\2` backreference) — this isn't
        // a real date shape any receipt actually prints, and allowing it
        // would widen the false-positive surface for no real benefit.
        let dates = ReceiptDateDetector.dates(in: "08/19-2026")
        XCTAssertTrue(dates.isEmpty)
    }

    func testInvalidCalendarDateIsRejectedNotNormalized() {
        // Foundation's `Calendar` silently rolls "02/30" forward into
        // March — that would fabricate a date that isn't printed anywhere,
        // which this detector must never do for the AI cross-check's sake.
        //
        // Prefixed with a year-like receipt number ("1077 ") so
        // NSDataDetector's own path drops the line entirely (the same
        // quirk this whole fix works around) — that isolates the
        // assertion to the regex pass's own rejection. A bare "02/30/2026"
        // isn't usable here: NSDataDetector normalizes it to March 2 on
        // its own, which is a pre-existing NSDataDetector leniency this
        // change doesn't touch, not something this test is about.
        let dates = ReceiptDateDetector.dates(in: "1077 02/30/2026")
        XCTAssertTrue(dates.isEmpty)
    }

    // MARK: - Full real-receipt layout text (see task: IMG_6392.JPEG)

    func testRealHomeDepotLayoutTextResolvesToTransactionDate() {
        // This is the exact layout-joined text `VisionLayoutService
        // .layoutString` produces for the real receipt image that exposed
        // this bug — single-space-joined tokens, a receipt number directly
        // before the date, and a future policy-expiry date that must not
        // win. `ReceiptDateDetector` itself should report *both* real
        // dates (08/19/2026 and the future 11/17/2026 — its job is "every
        // date printed"); it's `likelyReceiptDate`'s future-date rule that
        // narrows it down to the transaction date.
        let text = """
        1077 08/19/26 11:55 AM
        1077 61 46161 08/19/2026 1700
        POLICY ID RETURN POLICY DEFINITIONS
        DAYS POLICY EXPIRES ON
        11/17/2026
        """

        let allDates = Set(ReceiptDateDetector.dates(in: text).map { day($0) }.map { [$0.year, $0.month, $0.day] })
        XCTAssertTrue(allDates.contains([2026, 8, 19]))
        XCTAssertTrue(allDates.contains([2026, 11, 17]))

        let date = ManualEntryOCRPrefill.likelyReceiptDate(in: text)
        XCTAssertNotNil(date)
        let c = day(date!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 19)
    }
}
