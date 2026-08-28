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

    // MARK: - Negative cases: coarse date phrases stay with the model

    func testBareMonthNameIsLeftToTheModel() {
        // Must NOT become the single day July 1 — "in July" is a whole month,
        // which `named_month` already handles correctly.
        XCTAssertNil(parse("receipts in July", now: date(2026, 8, 28)))
    }

    func testMonthAndYearIsLeftToTheModel() {
        XCTAssertNil(parse("anything from July 2025", now: date(2026, 8, 28)))
    }

    func testRelativePhrasesAreLeftToTheModel() {
        XCTAssertNil(parse("anything from 2 weeks ago", now: date(2026, 8, 28)))
        XCTAssertNil(parse("in the last 30 days", now: date(2026, 8, 28)))
        XCTAssertNil(parse("from last month", now: date(2026, 8, 28)))
        XCTAssertNil(parse("so far this month", now: date(2026, 8, 28)))
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
