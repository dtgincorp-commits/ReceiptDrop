import XCTest
@testable import ReceiptDrop

/// Two fixes for false duplicate alarms, both from a real pair: "ZELLE TO
/// MORALES" ($410, Feb 3) and "ZELLE TO VATALE" ($50, Feb 4) — two different
/// people paid a day apart — were listed as possible duplicates.
///
/// 1. Vendor names are compared on the payee alone. The shared "Zelle" was
///    half of each two-word name, which namesMatch's 50% overlap counted as
///    the same vendor.
/// 2. "Not a Duplicate" lets the user dismiss any pair the rules still get
///    wrong, instead of the review screen's only way out being a delete.
final class DuplicatePayeeTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private var savedDismissals: Any?

    override func setUpWithError() throws {
        savedDismissals = defaults.object(forKey: AppConstants.DefaultsKeys.dismissedDuplicateGroups)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.dismissedDuplicateGroups)
    }

    override func tearDownWithError() throws {
        defaults.set(savedDismissals, forKey: AppConstants.DefaultsKeys.dismissedDuplicateGroups)
    }

    private func entry(_ vendor: String, _ date: String, _ amount: String) -> HistoryEntry {
        HistoryEntry(category: "HEATHERWOOD", vendor: vendor, workDate: date, amount: amount,
                     receiptLink: "\(UUID()).jpg", timestamp: Date())
    }

    // MARK: - Payee comparison

    func testPayeeNameDropsPaymentChannelWords() {
        XCTAssertEqual(DuplicateDetectionService.payeeName("ZELLE TO MORALES"), "to morales")
        XCTAssertEqual(DuplicateDetectionService.payeeName("SQ *BLUE BOTTLE"), "blue bottle")
        XCTAssertEqual(DuplicateDetectionService.payeeName("PAYPAL *ACME"), "acme")
        XCTAssertEqual(DuplicateDetectionService.payeeName("Cash App payment to Luis"), "to luis")
        XCTAssertEqual(DuplicateDetectionService.payeeName("Zelle payment to Monica"), "to monica")
    }

    func testPayeeNameKeepsRealBusinessNames() {
        XCTAssertEqual(DuplicateDetectionService.payeeName("Square One Pizza"), "square one pizza")
        XCTAssertEqual(DuplicateDetectionService.payeeName("Toast Kitchen"), "toast kitchen")
        XCTAssertEqual(DuplicateDetectionService.payeeName("Zelle"), "Zelle",
                       "a vendor that is only the service name still compares as itself")
    }

    func testZellePaymentsToDifferentPeopleAreNotDuplicates() {
        let groups = DuplicateDetectionService.findGroups(in: [
            entry("ZELLE TO MORALES", "2025-02-03", "410.00"),
            entry("ZELLE TO VATALE", "2025-02-04", "50.00"),
        ])
        XCTAssertTrue(groups.isEmpty, "\(groups.map(\.confidence))")
    }

    func testZellePaymentsToTheSamePersonAreStillFlagged() {
        let groups = DuplicateDetectionService.findGroups(in: [
            entry("ZELLE TO MORALES", "2025-02-03", "410.00"),
            entry("Zelle to Morales", "2025-02-04", "410.00"),
        ])
        XCTAssertEqual(groups.count, 1)
    }

    func testSameDaySameAmountToDifferentPayeesIsNoLongerLikely() {
        // Signal 1 still pairs same date + same amount on its own, but the
        // payee comparison now marks it as a different vendor, not likely.
        let groups = DuplicateDetectionService.findGroups(in: [
            entry("ZELLE TO MORALES", "2025-02-03", "50.00"),
            entry("ZELLE TO VATALE", "2025-02-03", "50.00"),
        ])
        XCTAssertEqual(groups.first?.confidence, .possibleDifferentVendor)
    }

    // MARK: - Not a Duplicate

    func testNotADuplicateHidesTheGroupFromThenOn() throws {
        let a = entry("Home Depot", "2025-03-01", "42.10")
        let b = entry("Home Depot", "2025-03-02", "42.10")
        let group = try XCTUnwrap(DuplicateDetectionService.findGroups(in: [a, b]).first)

        DuplicateDetectionService.markNotDuplicate(group)

        XCTAssertTrue(DuplicateDetectionService.findGroups(in: [a, b]).isEmpty)
        XCTAssertTrue(DuplicateDetectionService.findGroups(in: [b, a]).isEmpty,
                      "the decision must not depend on the order entries are listed in")
    }

    func testANewCopyBringsADismissedIdenticalFileGroupBack() throws {
        func copy() -> HistoryEntry {
            HistoryEntry(category: "C", vendor: "Noom", workDate: "2026-08-29", amount: "5700.00",
                         receiptLink: "\(UUID()).jpg", timestamp: Date(), fileHash: "abc123")
        }
        let first = copy(), second = copy()
        let group = try XCTUnwrap(DuplicateDetectionService.findGroups(in: [first, second]).first)
        DuplicateDetectionService.markNotDuplicate(group)

        let third = copy()
        let groups = DuplicateDetectionService.findGroups(in: [first, second, third])

        XCTAssertEqual(groups.first?.entries.count, 3,
                       "a third copy is new information; the earlier 'keep all' covered only two")
    }
}

final class AmountComparisonTests: XCTestCase {
    func testAmountsCompareByValueNotText() {
        XCTAssertTrue(DuplicateDetectionService.sameAmount("$50.00", "50.00"))
        XCTAssertTrue(DuplicateDetectionService.sameAmount("245.6", "245.60"))
        XCTAssertTrue(DuplicateDetectionService.sameAmount("$1,234.50", "1234.5"))
        XCTAssertTrue(DuplicateDetectionService.sameAmount(" 12.00 ", "12"))
        XCTAssertFalse(DuplicateDetectionService.sameAmount("50.00", "50.01"))
        XCTAssertFalse(DuplicateDetectionService.sameAmount("", "0.00"),
                       "no amount is not the same as an entered 0")
    }

    func testReferenceWordsInLongZelleVendorsDontCountAsTheSamePayee() {
        XCTAssertFalse(DuplicateDetectionService.vendorsMatch(
            "ZELLE TO ABDURRAHMAN ON 12/31 REF #RPOYDBQJNY MOVERS",
            "ZELLE TO VATALE ON 12/31 REF #RPOYHK4V4H"))
    }
}
