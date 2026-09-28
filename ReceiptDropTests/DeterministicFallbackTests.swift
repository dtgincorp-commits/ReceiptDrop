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

    func testTheFirstPrintedDateWinsWhenSeveralAreShown() {
        // Deliberately changed. This test used to assert that several dates
        // meant "default to today", on the principle that picking one would
        // be guessing. The fixture run showed that principle made the whole
        // fallback dead code — real receipts nearly always carry more than
        // one date-shaped string, so it never fired and all 8 date failures
        // still stored today.
        //
        // The choice here is not between a printed date and the model's
        // date; there is no model date. It is between the first printed date
        // and *today's*, which is certainly wrong. The transaction date is
        // the first date printed on almost every receipt, and the result
        // stays flagged, so the user still confirms.
        let twoDates = """
        SOME STORE, 100 MAIN ST, ANYTOWN CA 90210
        Ordered: 01/04/2026
        Delivered: 02/09/2026
        TOTAL $42.00
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Some Store", rawWorkDate: "", amount: "42.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: twoDates)

        XCTAssertEqual(receipt.workDate, "2026-01-04")
        XCTAssertTrue(receipt.needsReview, "A recovered date is still unconfirmed.")
    }

    func testNoPrintedDateAtAllStillDefaultsToTodayWithThePromptSuffix() {
        // The suffix other screens match on to raise the set-the-date
        // prompt. With nothing printed there is genuinely nothing to
        // recover, and that path must keep working.
        let noDates = """
        SOME STORE, 100 MAIN ST, ANYTOWN CA 90210
        THANK YOU FOR YOUR CUSTOM
        TOTAL $42.00
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Some Store", rawWorkDate: "", amount: "42.00", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: noDates)

        XCTAssertEqual(receipt.workDate, ExtractedReceipt.todayString())
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
        // "Manager" is jargon as well as mispositioned, so it is replaced.
        let receipt = ExtractedReceipt.build(
            vendor: "Manager", rawWorkDate: "2026-09-03", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: fullSlip)

        XCTAssertTrue(receipt.needsReview)
        XCTAssertNotEqual(receipt.vendor, "Manager",
                          "The deterministic read from the top of the receipt should win.")
    }

    func testAMispositionedButPlausibleNameIsFlaggedAndKept() {
        // The regression this pins. A plausible business name that simply
        // isn't at the top — an emailed receipt, a payment-app screenshot —
        // must be flagged but LEFT ALONE. Substituting on this signal alone
        // turned a correct "Felipe Monteras Tree Trimming" into the chat
        // chrome "Q Need help?" on the fixture set.
        let emailedReceipt = """
        Inbox
        Q Need help?
        All set!
        Mail · Today at 09:14
        To: neeraj@example.com
        Reply  Forward  Archive
        Thanks for your business, see the details below.
        Your receipt from Felipe Monteras Tree Trimming
        Service date 07/17/2026
        Amount charged $200.00
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Felipe Monteras Tree Trimming", rawWorkDate: "2026-07-17",
            amount: "200.00", comments: "", rawVendorType: "",
            modelReportedLowConfidence: false, modelReason: "", sourceText: emailedReceipt)

        XCTAssertEqual(receipt.vendor, "Felipe Monteras Tree Trimming",
                       "A plausible name must not be replaced just for sitting below a header.")
        XCTAssertTrue(receipt.needsReview)
    }

    func testTheRealNameIsFoundEvenWhenAnotherReceiptComesFirstInTheText() {
        // The exact failure from a live scan: "CRE" was flagged as jargon,
        // but the only candidate on offer was "Manager" — jargon too — from
        // the receipt intruding at the left edge of the frame. With nothing
        // acceptable to substitute, "CRE" was kept and saved.
        //
        // OCR order here puts the intruding receipt first, as it did on the
        // real photo.
        let twoReceipts = """
        Manager
        THU
        2 D  1 D  1 D
        Sub  Tax  Tota
        CRE
        NAAN AND KABOB LLC
        416 E 1ST ST
        TUSTIN, CA 92780
        09/03/2026
        PRE-TIP AMT  $89.93
        """
        let candidates = ManualEntryOCRPrefill.vendorCandidates(in: twoReceipts)
        XCTAssertGreaterThan(candidates.count, 1,
                             "One candidate is not enough when the first is unusable.")
        XCTAssertTrue(candidates.contains("NAAN AND KABOB LLC"), "\(candidates)")

        let receipt = ExtractedReceipt.build(
            vendor: "CRE", rawWorkDate: "2026-09-03", amount: "89.93", comments: "",
            rawVendorType: "", modelReportedLowConfidence: false, modelReason: "",
            sourceText: twoReceipts)
        XCTAssertEqual(receipt.vendor, "NAAN AND KABOB LLC")
        XCTAssertTrue(receipt.needsReview, "Substituting improves the name; it does not verify it.")
    }

    func testLikelyVendorLineStillReturnsTheFirstCandidate() {
        // Unchanged for its existing caller — prefilling a form field, where
        // one answer is all there is room for.
        let text = """
        MONTERAS CAFE
        3333 BRISTOL STREET
        COSTA MESA, CA 92626
        TOTAL $14.66
        """
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text),
                       ManualEntryOCRPrefill.vendorCandidates(in: text).first)
        XCTAssertEqual(ManualEntryOCRPrefill.likelyVendorLine(in: text), "MONTERAS CAFE")
    }

    // MARK: - Amount

    func testTheSequenceNumberIsReplacedByThePrintedTotal() {
        // $46 came from "SEQ #: 46" / "INVOICE 46" on a real scan. A bare
        // integer isn't currency-shaped, so the detector never counted it as
        // an amount — which is exactly why the cross-check caught it.
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "2026-09-03", amount: "46.00",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: fullSlip)

        XCTAssertEqual(receipt.amount, "89.93")
        XCTAssertTrue(receipt.needsReview)
    }

    func testAGratuitySuggestionIsCorrectedToThePrintedTotalAndFlagged() {
        // $13.48 is the 15% line, and it IS printed — so the not-printed
        // cross-check passes it silently and $13.48 lands in a tax record as
        // the cost of dinner. Caught only by comparing against what the
        // deterministic reader thinks the total is.
        //
        // This used to flag without replacing, on the reasoning that both
        // figures are genuinely printed so choosing between them is the
        // user's judgement. That deferred to the user in a case where the
        // evidence is not actually balanced: a grand total can never be
        // smaller than a component of it, so a labeled total that EXCEEDS
        // the model's figure means the model read a line — a gratuity
        // suggestion here, a line item on a multi-page invoice — and the
        // total line is simply the better answer. Substituting upward is
        // now the rule; see `ExtractedReceipt.build`.
        //
        // Still flagged, always. The substitution improves the stored
        // figure, it does not verify it. The opposite direction (a labeled
        // total SMALLER than the model's figure — a printed TOTAL with a
        // handwritten tip added on top) keeps the old flag-only behaviour,
        // covered by `testAHandwrittenTipAboveThePrintedTotalIsKept`.
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "2026-09-03", amount: "13.48",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: fullSlip)

        XCTAssertTrue(receipt.needsReview, "reason: \(receipt.reviewReason)")
        XCTAssertEqual(receipt.amount, "89.93")
        XCTAssertTrue(receipt.reviewReason.contains("89.93"),
                      "the better candidate should be named: \(receipt.reviewReason)")
    }

    func testAHandwrittenTipAboveThePrintedTotalIsKept() {
        // The asymmetry's other half, and the reason it exists: on a card
        // slip the printed TOTAL line is pre-tip, so a model reporting a
        // figure LARGER than that line is usually reading the handwritten
        // final amount — the truer number. Flag the disagreement, but never
        // overwrite the larger figure with the stale printed one.
        //
        // Needs its own slip rather than `fullSlip`: the tip total has to be
        // present in the text, or the not-printed branch handles it first
        // and this branch is never reached at all.
        let tippedSlip = """
        NAAN AND KABOB LLC
        416 E 1ST ST
        TUSTIN, CA 92780
        09/03/2026  18:26:34
        Sub-total  82.11
        Tax  7.82
        TOTAL  89.93
        TIP  15.00
        104.93
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "2026-09-03", amount: "104.93",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: tippedSlip)

        XCTAssertEqual(receipt.amount, "104.93")
        XCTAssertTrue(receipt.needsReview, "reason: \(receipt.reviewReason)")
    }

    func testACorrectAmountIsLeftAlone() {
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "2026-09-03", amount: "89.93",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: fullSlip)

        XCTAssertEqual(receipt.amount, "89.93")
        XCTAssertFalse(receipt.needsReview, receipt.reviewReason)
    }

    // MARK: - Amount: line item vs total

    /// Thai Cafe split check, as Vision read it on a real scan: the "$" on
    /// the Cashew Chicken line came back as a "5", so "$16.20" became
    /// "516.20" — a figure genuinely present in the text, and larger than
    /// every real number on the check. The model reported it as the total.
    private func thaiCafeText(cashewChickenPrice: String) -> String {
        """
        THAI CAFE
        Thai Cafe
        14715 Jeffrey Rd
        Irvine, CA 92618
        Server: Server 0
        Check #31   Table 8
        Guest Count: 2
        Ordered: 9/25/26 12:47 PM
        1 Cashew Chicken   \(cashewChickenPrice)
        1 Phad Kee Mao   $14.95
        Subtotal   $31.15
        Tax   $2.42
        Total   $33.57
        Input Type   C (EMV Chip Read)
        VISA CREDIT   xxxxxxxx4956
        Time   1:19 PM
        Previous Payment Total:   $16.78
        Tips Previously Paid:   $2.34
        Amount   $16.79
        + Tip:   $3.12
        = Total:   $19.91
        VISA CARDHOLDER
        """
    }

    func testAMisreadLineItemPriceIsReplacedByTheSmallerPrintedTotal() {
        // The case the smaller-total rule was never meant to protect. That
        // rule keeps a figure ABOVE the printed Total because on a card slip
        // it is usually the handwritten tip total. 516.20 is not that: it
        // sits on a line naming a dish, and a total can never be smaller
        // than one of its own line items.
        let receipt = ExtractedReceipt.build(
            vendor: "Thai Cafe", rawWorkDate: "2026-09-25", amount: "516.20",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false,
            modelReason: "", sourceText: thaiCafeText(cashewChickenPrice: "516.20"))

        XCTAssertEqual(receipt.amount, "33.57")
        XCTAssertTrue(receipt.needsReview, "Substituting improves the figure; it does not verify it.")
        XCTAssertTrue(receipt.reviewReason.contains("516.20"),
                      "the rejected figure must still be named: \(receipt.reviewReason)")
    }

    func testAModelMisreadOfACorrectlyReadLineItemIsStillReplaced() {
        // Same receipt, but Vision read "$16.20" correctly and only the
        // model got it wrong. Already handled by the not-printed branch;
        // here so the new rule can't disturb it.
        let receipt = ExtractedReceipt.build(
            vendor: "Thai Cafe", rawWorkDate: "2026-09-25", amount: "516.20",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false,
            modelReason: "", sourceText: thaiCafeText(cashewChickenPrice: "$16.20"))

        XCTAssertEqual(receipt.amount, "33.57")
        XCTAssertTrue(receipt.needsReview)
    }

    func testALineItemAboveADiscountedTotalIsReplaced() {
        // The same rule without any OCR error: a discount after the item
        // makes the real total smaller than the item it contains.
        let text = """
        BEST ELECTRONICS
        200 Main St
        09/03/2026  14:02
        Laptop   1000.00
        Discount   -200.00
        Subtotal   800.00
        Tax   72.00
        Total   872.00
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Best Electronics", rawWorkDate: "2026-09-03", amount: "1000.00",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertEqual(receipt.amount, "872.00")
        XCTAssertTrue(receipt.needsReview)
    }

    func testACardChargeAboveThePrintedTotalIsKept() {
        // The line-item rule must not reach payment lines. A VISA line
        // larger than the printed Total is the tip-included charge — the
        // truer number, exactly as `testAHandwrittenTipAboveThePrintedTotalIsKept`
        // protects for a bare figure.
        let text = """
        NAAN AND KABOB LLC
        416 E 1ST ST
        TUSTIN, CA 92780
        09/03/2026  18:26:34
        Sub-total  82.11
        Tax  7.82
        TOTAL  89.93
        VISA  104.93
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Naan and Kabob", rawWorkDate: "2026-09-03", amount: "104.93",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertEqual(receipt.amount, "104.93")
        XCTAssertTrue(receipt.needsReview, "the disagreement is still flagged")
    }

    func testASingleItemReceiptWhoseItemEqualsItsTotalIsLeftAlone() {
        let text = """
        TACO SHOP
        12 Harbor Blvd
        09/03/2026  12:15
        1 Burrito   12.50
        Total   12.50
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Taco Shop", rawWorkDate: "2026-09-03", amount: "12.50",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertEqual(receipt.amount, "12.50")
        XCTAssertFalse(receipt.needsReview, receipt.reviewReason)
    }

    func testAMisreadLineItemSplitFromItsNameIsAtLeastFlagged() {
        // Vision often reads a photographed receipt column-wise, putting the
        // price on its own line with no dish name beside it. Nothing then
        // shows 516.20 is a line item, so the rule can't safely substitute
        // — but the disagreement with the Total must still be flagged.
        let text = """
        THAI CAFE
        14715 Jeffrey Rd
        Ordered: 9/25/26 12:47 PM
        1 Cashew Chicken
        1 Phad Kee Mao
        516.20
        $14.95
        Subtotal   $31.15
        Tax   $2.42
        Total   $33.57
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Thai Cafe", rawWorkDate: "2026-09-25", amount: "516.20",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertTrue(receipt.needsReview)
    }

    func testTheLargestNumberFallbackNeverOverwritesTheModelsAmount() {
        // The real failure, from the phone's own saved record: the model
        // read $19.91 — this card's charge, a correct answer — and the
        // guardrail replaced it with $516.20, claiming "from the receipt's
        // Total line". There was no Total line to read: Vision read this
        // receipt column-wise (verbatim below, apart from the misread), so
        // no label shares a line with its number and `BillTotalsParser`
        // found nothing. `likelyGrandTotal` then fell back to the largest
        // number on the receipt, which was the misread "516.20". A guess is
        // not evidence enough to overwrite an answer that is printed there.
        let text = """
        THAI CAFE
        Thai Cafe
        14715 Jeffrey
        Rd
        Irvine. CA
        92618
        Server: Server 0
        Check #31
        Guest Count: 2
        Ordered:
        Table 8
        9/25/26 12:47 PM
        1 Casheu Chicken
        1 Phad Kee Mao
        516.20
        $14.95
        Subtotal
        Tax
        Total
        $31.15
        $2.42
        $33.57
        Input Type
        VISA
        CREDIT
        Time
        Transaction Type
        Authorization
        Approval Code
        C (EMU Chip Read)
        xxxxxxxx4956
        1:19 PM
        Sale
        Approved
        07970G
        Previous Payment Total:
        Tips Previously Paid:
        Anount
        + Tip:
        = Total:
        VISA CARDHOLDER
        $16.78
        $2.34
        $16.79
        $3.12
        $19.91
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Thai Cafe", rawWorkDate: "2026-09-25", amount: "19.91",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertEqual(receipt.amount, "19.91")
    }

    // MARK: - Amount: arithmetic check

    func testATotalFarAboveSubtotalPlusTaxIsFlagged() {
        // The misread lands on the Total line itself, so the model and the
        // Total line agree on 533.57 and nothing else objects. Only the
        // arithmetic shows it: 31.15 + 2.42 is 33.57. Flag only — which of
        // the three lines is wrong can't be told from the sum alone.
        let text = """
        THAI CAFE
        14715 Jeffrey Rd
        Ordered: 9/25/26 12:47 PM
        1 Cashew Chicken   $16.20
        1 Phad Kee Mao   $14.95
        Subtotal   $31.15
        Tax   $2.42
        Total   533.57
        """
        let receipt = ExtractedReceipt.build(
            vendor: "Thai Cafe", rawWorkDate: "2026-09-25", amount: "533.57",
            comments: "", rawVendorType: "restaurant", modelReportedLowConfidence: false,
            modelReason: "", sourceText: text)

        XCTAssertEqual(receipt.amount, "533.57", "flag only, never substitute")
        XCTAssertTrue(receipt.needsReview)
        XCTAssertTrue(receipt.reviewReason.contains("33.57"),
                      "the expected sum should be named: \(receipt.reviewReason)")
    }

    func testTipsAndExtraTaxLinesDoNotTripTheArithmeticCheck() {
        // Receipts routinely total more than subtotal + the first tax line:
        // a second tax, a service charge, a tip written into the Total. The
        // check must stay quiet for all of them.
        let secondTax = """
        CAFE ROUGE
        09/03/2026  19:40
        Subtotal  82.11
        Tax  7.82
        City Tax  1.50
        Total  91.43
        """
        let tipInTotal = """
        CAFE ROUGE
        09/03/2026  19:40
        Subtotal  82.11
        Tax  7.82
        Tip  25.00
        Total  114.93
        """
        for text in [secondTax, tipInTotal] {
            let amount = BillTotalsParser.extractTotals(from: text).total
            let receipt = ExtractedReceipt.build(
                vendor: "Cafe Rouge", rawWorkDate: "2026-09-03", amount: amount,
                comments: "", rawVendorType: "", modelReportedLowConfidence: false,
                modelReason: "", sourceText: text)

            XCTAssertEqual(receipt.amount, amount)
            XCTAssertFalse(receipt.needsReview, "\(amount): \(receipt.reviewReason)")
        }
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
