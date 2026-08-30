import XCTest
@testable import ReceiptDrop

/// Insights used to group categories and vendors on the raw stored string,
/// so spellings differing only in case became separate rows. The confirmed
/// case: "SAMPLE CATEGORY" ($889.03) and "Sample Category" ($258.01) shown
/// as two categories, while the Categories screen — which had already been
/// made case-insensitive — showed one. Same money, two headings, and no
/// total in Insights matching what the rest of the app reported.
final class InsightsCaseGroupingTests: XCTestCase {
    private func entry(category: String, vendor: String, amount: String,
                       daysAgo: Int = 3) -> HistoryEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = AppConstants.sheetDateFormat
        return HistoryEntry(category: category, vendor: vendor,
                            workDate: f.string(from: date), amount: amount,
                            receiptLink: "\(UUID().uuidString).jpg", timestamp: date)
    }

    func testCategorySpellingsDifferingOnlyInCaseBecomeOneRow() {
        let digest = SpendingInsightsService.buildDigest(from: [
            entry(category: "SAMPLE CATEGORY", vendor: "A", amount: "889.03"),
            entry(category: "Sample Category", vendor: "B", amount: "258.01"),
        ])
        XCTAssertEqual(digest.byCategory.count, 1)
        XCTAssertEqual(digest.byCategory.first?.total ?? 0, 1147.04, accuracy: 0.001)
        XCTAssertEqual(digest.byCategory.first?.count, 2)
    }

    /// The label must be a spelling that actually exists, not the uppercased
    /// grouping key — otherwise every user sees "COSTCO" for "Costco".
    func testLabelUsesTheMostCommonSpellingNotTheGroupingKey() {
        let digest = SpendingInsightsService.buildDigest(from: [
            entry(category: "Heatherwood", vendor: "A", amount: "10.00"),
            entry(category: "Heatherwood", vendor: "B", amount: "10.00"),
            entry(category: "HEATHERWOOD", vendor: "C", amount: "10.00"),
        ])
        XCTAssertEqual(digest.byCategory.first?.label, "Heatherwood")
    }

    /// Vendor names are AI-extracted and providers disagree on capitalization
    /// for the same business, so Top Vendors split one merchant in two and
    /// understated it.
    func testVendorSpellingsDifferingOnlyInCaseBecomeOneRow() {
        let digest = SpendingInsightsService.buildDigest(from: [
            entry(category: "DTG", vendor: "Home Depot", amount: "100.00"),
            entry(category: "DTG", vendor: "HOME DEPOT", amount: "50.00"),
        ])
        XCTAssertEqual(digest.topVendors.count, 1)
        XCTAssertEqual(digest.topVendors.first?.total ?? 0, 150.0, accuracy: 0.001)
    }

    /// Genuinely different names must still be separate — the fix folds case,
    /// nothing else.
    func testDifferentCategoriesAreStillSeparate() {
        let digest = SpendingInsightsService.buildDigest(from: [
            entry(category: "DTG", vendor: "A", amount: "10.00"),
            entry(category: "MONTERAS", vendor: "B", amount: "20.00"),
        ])
        XCTAssertEqual(digest.byCategory.count, 2)
    }
}
