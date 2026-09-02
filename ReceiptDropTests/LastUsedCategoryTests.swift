import XCTest
@testable import ReceiptDrop

/// Covers `LastUsedCategoryStore` — the category the share extension files
/// under when it parks a receipt without asking.
///
/// This is load-bearing in a way that is easy to miss: the extension has no
/// UI, so if this returns something wrong the receipt is silently filed
/// somewhere the user did not choose, and nothing prompts them to look.
final class LastUsedCategoryTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private let key = AppConstants.DefaultsKeys.lastUsedCategory

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: key)
    }

    override func tearDown() {
        defaults.removeObject(forKey: key)
        super.tearDown()
    }

    func testFallsBackToTheFirstCategoryWhenNothingHasBeenFiled() {
        let expected = CategoryStore.shared.categories.first ?? AppConstants.defaultCategories[0]
        XCTAssertEqual(LastUsedCategoryStore.current, expected)
    }

    func testRemembersWhatWasRecorded() {
        guard let existing = CategoryStore.shared.categories.first else {
            return XCTFail("Expected at least one seeded category.")
        }
        LastUsedCategoryStore.record(existing)
        XCTAssertEqual(LastUsedCategoryStore.current, existing)
    }

    func testIgnoresACategoryThatNoLongerExists() {
        // The user renamed or deleted the category since it was recorded.
        // Returning it anyway would have LocalReceiptStore recreate it as a
        // stray folder the user never asked for and would not find.
        defaults.set("A CATEGORY THAT WAS DELETED", forKey: key)
        XCTAssertNotEqual(LastUsedCategoryStore.current, "A CATEGORY THAT WAS DELETED")
        XCTAssertTrue(CategoryStore.shared.categories.contains(LastUsedCategoryStore.current))
    }

    func testRecordingAnEmptyCategoryIsIgnored() {
        guard let existing = CategoryStore.shared.categories.first else {
            return XCTFail("Expected at least one seeded category.")
        }
        LastUsedCategoryStore.record(existing)
        LastUsedCategoryStore.record("")
        XCTAssertEqual(LastUsedCategoryStore.current, existing)
    }

    func testCurrentIsAlwaysAUsableCategory() {
        // The extension files straight into whatever this returns, with no
        // human in the loop — an empty string would mean a receipt parked
        // into no category at all.
        XCTAssertFalse(LastUsedCategoryStore.current.isEmpty)
    }
}
