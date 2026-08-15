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

    func testFabricatedAmountIsFlaggedNotCorrected() {
        // The actual bug: model returns a plausible-looking total that
        // appears nowhere on the receipt. Unlike the date guardrail, this
        // must NOT auto-correct — the amount stays exactly as reported,
        // just flagged, since a receipt has too many numbers to safely
        // guess which one is "the" total.
        let r = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: recentDate, amount: "142.51",
            comments: "", rawVendorType: "restaurant",
            modelReportedLowConfidence: false, modelReason: "",
            sourceText: naanAndKabobText)
        XCTAssertEqual(r.amount, "142.51", "amount must be left unchanged — flag only, never auto-correct")
        XCTAssertTrue(r.needsReview)
        XCTAssertTrue(r.reviewReason.contains("142.51"))
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

    // MARK: - Duplicate detection: tip-shaped amounts waive the date window

    private func entry(_ vendor: String, _ date: String, _ amount: String) -> HistoryEntry {
        HistoryEntry(category: "DTG", vendor: vendor, workDate: date, amount: amount,
                     receiptLink: "\(UUID().uuidString).jpg", timestamp: Date())
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
}

private extension DateFormatter {
    static let posixDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return f
    }()
}
