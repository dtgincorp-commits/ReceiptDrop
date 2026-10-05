import XCTest
@testable import ReceiptDrop

/// Real stored history holds amounts written both ways — "50.00" and
/// "$50.00" — and everything that turned them into numbers with
/// `Double(amount)` silently dropped the second: the Receipts total,
/// Insights, and the instant amount search all left those receipts out.
final class AmountReadingTests: XCTestCase {
    private func entry(_ amount: String) -> HistoryEntry {
        HistoryEntry(category: "C", vendor: "V", workDate: "2026-09-01", amount: amount,
                     receiptLink: "x.jpg", timestamp: Date())
    }

    func testStoredAmountsReadTheSameWithOrWithoutASymbol() {
        XCTAssertEqual(entry("50.00").amountValue, 50)
        XCTAssertEqual(entry("$50.00").amountValue, 50)
        XCTAssertEqual(entry("$1,234.50").amountValue, 1234.5)
        XCTAssertNil(entry("").amountValue)
        XCTAssertNil(entry("abc").amountValue)
    }

    // MARK: - Stopping it at the source

    func testAModelAmountWrittenAsMoneyIsStoredAsAPlainNumber() {
        XCTAssertEqual(ExtractedReceipt.plainAmount("$50.00"), "50.00")
        XCTAssertEqual(ExtractedReceipt.plainAmount("$1,234.50"), "1234.50")
        XCTAssertEqual(ExtractedReceipt.plainAmount(" $7.5 "), "7.50")
    }

    func testPlainOrUnreadableAmountsPassThroughUntouched() {
        for raw in ["245.6", "50.00", "-12.00", "", "abc"] {
            XCTAssertEqual(ExtractedReceipt.plainAmount(raw), raw)
        }
    }

    func testAMoneyFormattedAmountIsNoLongerFlaggedAsUnreadable() {
        let r = ExtractedReceipt.build(
            vendor: "Home Depot", rawWorkDate: "2026-09-01", amount: "$42.10",
            comments: "", rawVendorType: "", modelReportedLowConfidence: false, modelReason: "")
        XCTAssertEqual(r.amount, "42.10")
        XCTAssertFalse(r.reviewReason.contains("unreadable"), r.reviewReason)
    }

    // MARK: - Instant search

    private func matches(_ query: String, _ amount: Double) -> Bool? {
        ReceiptsView.parseAmountConditions(query).map { conditions in
            conditions.allSatisfy { ReceiptsView.satisfies(amount: amount, condition: $0) }
        }
    }

    func testInstantSearchUnderstandsEquals() {
        for query in ["=20", "==20", "= $20", "=20.00"] {
            XCTAssertEqual(matches(query, 20), true, query)
            XCTAssertEqual(matches(query, 20.01), false, query)
        }
    }

    func testInstantSearchComparisonsAreUnchanged() {
        XCTAssertEqual(matches(">20", 20), false)
        XCTAssertEqual(matches(">=20", 20), true)
        XCTAssertEqual(matches("<20", 20), false)
        XCTAssertEqual(matches("<=20", 20), true)
        XCTAssertEqual(matches(">= 20 and <= 40", 30), true)
        XCTAssertEqual(matches(">= 20 and <= 40", 40.01), false)
        XCTAssertNil(matches("starbucks", 20), "not an amount query: falls back to text search")
    }
}
