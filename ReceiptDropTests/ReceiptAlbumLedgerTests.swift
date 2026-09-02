import XCTest
@testable import ReceiptDrop

/// Covers `ImportedAssetLedger` — the record of which photo-library assets
/// have already been filed from the "Receipts Only" album.
///
/// No PhotoKit here: the ledger deals in identifier strings, so it is
/// testable without a photo library or a device. The album service around it
/// is not, which is exactly why the dedupe logic lives in a separate type.
final class ReceiptAlbumLedgerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ImportedAssetLedger.forget(Array(ImportedAssetLedger.filedIdentifiers()))
    }

    override func tearDown() {
        ImportedAssetLedger.forget(Array(ImportedAssetLedger.filedIdentifiers()))
        super.tearDown()
    }

    func testMarkingAnAssetFiledKeepsItOutOfTheNextScan() {
        ImportedAssetLedger.markFiled(["ABC-123/L0/001"])
        XCTAssertTrue(ImportedAssetLedger.filedIdentifiers().contains("ABC-123/L0/001"))
    }

    func testMarkingIsAdditiveRatherThanReplacing() {
        // A second import must not forget the first — otherwise every batch
        // re-offers everything filed before it.
        ImportedAssetLedger.markFiled(["one"])
        ImportedAssetLedger.markFiled(["two", "three"])
        XCTAssertEqual(ImportedAssetLedger.filedIdentifiers(), ["one", "two", "three"])
    }

    func testMarkingTheSameAssetTwiceDoesNotDuplicateIt() {
        ImportedAssetLedger.markFiled(["one"])
        ImportedAssetLedger.markFiled(["one"])
        XCTAssertEqual(ImportedAssetLedger.filedIdentifiers().count, 1)
    }

    func testForgettingLetsAnAssetBeOfferedAgain() {
        // The escape hatch for a mis-imported receipt the user deleted and
        // wants to re-file — without it the asset is invisible forever.
        ImportedAssetLedger.markFiled(["one", "two"])
        ImportedAssetLedger.forget(["one"])
        XCTAssertEqual(ImportedAssetLedger.filedIdentifiers(), ["two"])
    }

    func testMarkingNothingIsANoOp() {
        ImportedAssetLedger.markFiled(["one"])
        ImportedAssetLedger.markFiled([])
        XCTAssertEqual(ImportedAssetLedger.filedIdentifiers(), ["one"])
    }
}
