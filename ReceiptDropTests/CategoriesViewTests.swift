import XCTest
@testable import ReceiptDrop

/// Covers `CategoriesView.receiptCount(for:in:)`, the pure half of the
/// per-category count that used to call `SubmissionStore.loadHistory()`
/// (a UserDefaults read + full JSON decode) once per row on every redraw.
/// The fix loads history once into `@State` and derives counts from that
/// cached array instead — this is the part of that fix that's actually
/// testable without a live App Group `UserDefaults` suite.
final class CategoriesViewTests: XCTestCase {

    private func entry(category: String) -> HistoryEntry {
        HistoryEntry(
            category: category, vendor: "Vendor", workDate: "2026-01-01",
            amount: "1.00", receiptLink: "r.jpg", timestamp: Date())
    }

    func testCountsOnlyMatchingCategory() {
        let history = [
            entry(category: "OFFICE SUPPLIES"),
            entry(category: "OFFICE SUPPLIES"),
            entry(category: "TRAVEL"),
        ]
        XCTAssertEqual(CategoriesView.receiptCount(for: "OFFICE SUPPLIES", in: history), 2)
        XCTAssertEqual(CategoriesView.receiptCount(for: "TRAVEL", in: history), 1)
    }

    func testCountIsCaseInsensitive() {
        // Restored backups can carry mixed-case category names (see the
        // doc comment on `receiptCount` in CategoriesView.swift) — the
        // count must still find them under the list's uppercase name.
        let history = [
            entry(category: "Sample Category"),
            entry(category: "SAMPLE CATEGORY"),
            entry(category: "sample category"),
        ]
        XCTAssertEqual(CategoriesView.receiptCount(for: "SAMPLE CATEGORY", in: history), 3)
    }

    func testCountIsZeroForUnrelatedCategory() {
        let history = [entry(category: "TRAVEL")]
        XCTAssertEqual(CategoriesView.receiptCount(for: "OFFICE SUPPLIES", in: history), 0)
    }

    func testCountIsZeroForEmptyHistory() {
        XCTAssertEqual(CategoriesView.receiptCount(for: "TRAVEL", in: []), 0)
    }
}
