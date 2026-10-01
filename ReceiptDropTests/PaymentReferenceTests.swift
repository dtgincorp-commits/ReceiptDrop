import XCTest
@testable import ReceiptDrop

/// Payment references settle a suspected duplicate: shared → the same
/// payment, none shared → different payments, missing on either side →
/// nothing to conclude. Text below is shaped like real OCR of the Zelle
/// screenshots that motivated this.
final class PaymentReferenceTests: XCTestCase {

    // MARK: - Reading references

    func testReadsEveryZelleReferenceInOneScreenshot() {
        let text = """
        02/03/2025
        ZELLE TO MORALES
        MONICA ON 02/02 REF
        #PP0YHCL3XF
        $210.00
        01/27/2025
        ZELLE TO MORALES
        MONICA ON 01/26 REF
        #PP0YGMK3V2
        $200.00
        """
        XCTAssertEqual(PaymentReference.find(in: text), ["PP0YHCL3XF", "PP0YGMK3V2"])
    }

    func testReadsTheZeroThatVisionReadsAsTheLetterO() {
        // Verbatim Vision OCR of the real screenshot: REF #PP0YHCL3XF came
        // back as "PPOYHCL3XF". Folded back, so a second photo of the same
        // payment read correctly still matches.
        XCTAssertEqual(PaymentReference.find(in: "MONICA ON 02/02 REF\n#PPOYHCL3XF"), ["PP0YHCL3XF"])
        XCTAssertEqual(PaymentReference.compare(PaymentReference.find(in: "REF #PPOYHCL3XF"),
                                                PaymentReference.find(in: "REF #PP0YHCL3XF")),
                       .samePayment("PP0YHCL3XF"))
    }

    func testReadsReferenceOnTheSameLine() {
        XCTAssertEqual(PaymentReference.find(in: "ZELLE TO VATALE HANDYMAN ON 02/04 REF #RP0YHK4V4H THANKS"),
                       ["RP0YHK4V4H"])
    }

    func testReadsOtherCommonLabels() {
        XCTAssertEqual(PaymentReference.find(in: "Transaction ID: 9KD12345AB678901C"), ["9KD12345AB678901C"])
        XCTAssertEqual(PaymentReference.find(in: "Confirmation # ab12cd34"), ["AB12CD34"])
        XCTAssertEqual(PaymentReference.find(in: "Payment ID 4XJ29KQ7"), ["4XJ29KQ7"])
    }

    func testIgnoresLabelsFollowedByOrdinaryWords() {
        XCTAssertTrue(PaymentReference.find(in: "Reference Number\nApplication Label").isEmpty)
        XCTAssertTrue(PaymentReference.find(in: "Please keep this confirmation for your records").isEmpty)
        // A card slip's all-letter Payment ID isn't taken: every real
        // payment-app reference seen so far contains a digit.
        XCTAssertTrue(PaymentReference.find(in: "Payment ID XjmYrXPpKYWg").isEmpty)
        // Folding O/I into digits must not turn a word into a "reference".
        XCTAssertTrue(PaymentReference.find(in: "Reference Number Application").isEmpty)
    }

    func testTheRealVataleScreenshotReadsItsReference() {
        // Verbatim Vision OCR of the user's second screenshot.
        let text = "02/04/2025\nZELLE TO VATALE\nHANDYMAN ON 02/04\nREF #RPOYHK4V4H\nTHANKS FOR THE\nHANDYMAN WORK\n$50.00"
        XCTAssertEqual(PaymentReference.find(in: text), ["RP0YHK4V4H"])
    }

    // MARK: - Comparing

    func testSharedReferenceMeansTheSamePayment() {
        XCTAssertEqual(PaymentReference.compare(["PP0YHCL3XF", "PP0YGMK3V2"], ["PP0YHCL3XF"]),
                       .samePayment("PP0YHCL3XF"))
    }

    func testNoSharedReferenceMeansDifferentPayments() {
        XCTAssertEqual(PaymentReference.compare(["PP0YHCL3XF"], ["RP0YHK4V4H"]), .differentPayments)
    }

    func testReferencesThatDifferOnlyByOCRNoiseProveNothing() {
        // One reference read two ways (a single misread character) must not
        // be called two different payments — that would hide a real
        // duplicate. It falls back to the ordinary warning instead.
        XCTAssertEqual(PaymentReference.compare(["PP0YHCL3XF"], ["PP0YHCL8XF"]), .unknown)
        XCTAssertEqual(PaymentReference.compare(["PP0YHCL3XF"], ["PP0YHCL3X"]), .unknown)
    }

    func testEditDistance() {
        XCTAssertEqual(PaymentReference.editDistance("PP0YHCL3XF", "PP0YHCL3XF"), 0)
        XCTAssertEqual(PaymentReference.editDistance("PP0YHCL3XF", "PP0YHCL8XF"), 1)
        XCTAssertEqual(PaymentReference.editDistance("", "ABC"), 3)
        XCTAssertGreaterThan(PaymentReference.editDistance("PP0YHCL3XF", "RP0YHK4V4H"), 2)
    }

    func testAMissingReferenceProvesNothing() {
        XCTAssertEqual(PaymentReference.compare([], ["RP0YHK4V4H"]), .unknown)
        XCTAssertEqual(PaymentReference.compare(["PP0YHCL3XF"], []), .unknown)
    }

    // MARK: - Save-time check

    func testTheSaveTimeCheckStaysAGuessWithoutReferencesToCompare() async throws {
        let category = "TestCategory_\(UUID().uuidString.prefix(8))"
        let existing = HistoryEntry(category: category, vendor: "Coffee", workDate: "2026-09-01",
                                    amount: "4.50", receiptLink: SubmissionPipeline.manualEntryLabel,
                                    timestamp: Date())
        SubmissionStore.appendHistory(existing)
        defer { SubmissionStore.removeHistory(existing) }

        var readIncoming = false
        let result = await SubmissionPipeline.fieldMatchDuplicate(
            category: category, workDate: "2026-09-01", amount: "4.50",
            newReferences: { readIncoming = true; return ["PP0YHCL3XF"] })

        XCTAssertTrue(readIncoming)
        XCTAssertEqual(result?.0.id, existing.id)
        XCTAssertEqual(result?.1, .matchingFields,
                       "the saved receipt has no photo to read, so the old guess stands")
    }

    func testTheNewReceiptIsOnlyReadWhenSomethingAlreadyMatches() async {
        var readIncoming = false
        let result = await SubmissionPipeline.fieldMatchDuplicate(
            category: "NoSuchCategory_\(UUID().uuidString)", workDate: "2026-09-01", amount: "4.50",
            newReferences: { readIncoming = true; return [] })

        XCTAssertNil(result)
        XCTAssertFalse(readIncoming, "an ordinary save must never pay for OCR")
    }
}

/// The five real Zelle receipts this feature was built against: vendor,
/// date and amount exactly as stored on the phone, and the receipt text
/// exactly as Vision read each photo. Note the stored amounts mix "$50.00"
/// and "50.00", and Vision reads the zero in "P0Y"/"R0Y" as either 0 or O.
final class RealZelleReceiptTests: XCTestCase {
    private struct Receipt {
        let vendor, date, amount, ocr: String
        let references: Set<String>
    }

    private let receipts = [
        Receipt(vendor: "ZELLE TO MORALES", date: "2024-12-23", amount: "220.00",
                ocr: "12/23/2024\nZELLE TO MORALES\nMONICA ON 12/22 REF\n#PPOYCKTBS9\n$220.00",
                references: ["PP0YCKTBS9"]),
        Receipt(vendor: "ZELLE TO ABDURRAHMAN ON 12/31 REF #RPOYDBQJNY MOVERS", date: "2024-12-31", amount: "$50.00",
                ocr: "12/31/2024\nZELLE TO\nABDURRAHMAN ON\n12/31 REF\n#RPOYDBQJNY MOVERS\n$50.00",
                references: ["RP0YDBQJNY"]),
        Receipt(vendor: "ZELLE TO MORALES", date: "2025-02-03", amount: "$410.00",
                ocr: "02/03/2025\nZELLE TO MORALES\nMONICA ON 02/02 REF\n#PP0YHCL3XF\n01/27/2025\nZELLE TO MORALES\nMONICA ON 01/26 REF\n#PPOYGMK3V2\n$210.00\n$200.00",
                references: ["PP0YHCL3XF", "PP0YGMK3V2"]),
        Receipt(vendor: "ZELLE TO VATALE", date: "2025-02-04", amount: "50.00",
                ocr: "02/04/2025\nZELLE TO VATALE\nHANDYMAN ON 02/04\nREF #RPOYHK4V4H\nTHANKS FOR THE\nHANDYMAN WORK\n$50.00",
                references: ["RP0YHK4V4H"]),
        Receipt(vendor: "ZELLE TO BALENCIA MONICA ON 02/14 REF #PPOYJJX33S LAGUNA CLEANING", date: "2025-02-14", amount: "125.00",
                ocr: "<\n(Q Need...\nTransaction details\n$125.00\nTransaction: 02/14/2025\nPosted: 02/14/2025\n3\nSign off\nAdditional info\nCategory\nOther Outgoing Transfers\nTransaction description\nZELLE TO BALENCIA MONICA ON\n02/14 REF #PPOYJJX33S LAGUNA\nCLEANING",
                references: ["PP0YJJX33S"]),
    ]

    private func entry(_ r: Receipt) -> HistoryEntry {
        HistoryEntry(category: "HEATHERWOOD", vendor: r.vendor, workDate: r.date, amount: r.amount,
                     receiptLink: "\(UUID()).jpg", timestamp: Date())
    }

    func testEveryReferenceIsReadFromTheRealText() {
        for r in receipts {
            XCTAssertEqual(PaymentReference.find(in: r.ocr), r.references, r.vendor)
        }
    }

    func testEveryPairOfRealReceiptsIsTellableApartByReference() {
        // Different payments must come out as different — and never as
        // "unknown" through the OCR-noise allowance, which would let a real
        // pair of different payments fall back to a duplicate warning.
        for (i, a) in receipts.enumerated() {
            for b in receipts[(i + 1)...] {
                XCTAssertEqual(PaymentReference.compare(a.references, b.references), .differentPayments,
                               "\(a.vendor) vs \(b.vendor)")
            }
        }
    }

    func testNoneOfTheRealReceiptsAreSuspectedDuplicates() {
        XCTAssertTrue(DuplicateDetectionService.findGroups(in: receipts.map(entry)).isEmpty)
    }

    func testTheSameReceiptScannedTwiceIsStillCaughtDespiteDollarSigns() {
        // The Vatale receipt is stored as "50.00"; a second scan that comes
        // back as "$50.00" is the same amount.
        let first = entry(receipts[3])
        let again = HistoryEntry(category: "HEATHERWOOD", vendor: "Zelle to Vatale", workDate: "2025-02-04",
                                 amount: "$50.00", receiptLink: "\(UUID()).jpg", timestamp: Date())
        let groups = DuplicateDetectionService.findGroups(in: [first, again])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.confidence, .likely)
        XCTAssertEqual(PaymentReference.compare(receipts[3].references,
                                                PaymentReference.find(in: receipts[3].ocr)),
                       .samePayment("RP0YHK4V4H"))
    }

    func testTheSaveTimeCheckMatchesAmountsWrittenDifferently() async {
        let category = "TestCategory_\(UUID().uuidString.prefix(8))"
        let stored = HistoryEntry(category: category, vendor: "ZELLE TO VATALE", workDate: "2025-02-04",
                                  amount: "50.00", receiptLink: SubmissionPipeline.manualEntryLabel, timestamp: Date())
        SubmissionStore.appendHistory(stored)
        defer { SubmissionStore.removeHistory(stored) }

        let result = await SubmissionPipeline.fieldMatchDuplicate(
            category: category, workDate: "2025-02-04", amount: "$50.00", newReferences: { [] })

        XCTAssertEqual(result?.0.id, stored.id, "$50.00 and 50.00 are the same amount")
    }
}
