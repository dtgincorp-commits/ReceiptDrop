import XCTest
@testable import ReceiptDrop

/// Tests `LocalReceiptStore.importFile`'s no-overwrite guarantee — the
/// safety property `RestoreService`'s photo-reattach logic (see
/// `RESTORE_MISSING_PHOTOS_PLAN.md`) depends on: copying files for entries
/// already in history is only safe because `importFile` never overwrites an
/// existing destination file.
///
/// NOT covered here: `RestoreService.restore` end-to-end (real zip
/// extraction, App Group storage, history merging) — that would need a
/// synthetic backup zip and App Group test doubles this suite doesn't set
/// up. This file verifies the one property the restore change relies on,
/// directly, at the level where it's actually implemented.
final class LocalReceiptStoreTests: XCTestCase {
    private var testCategory: String!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        testCategory = "TestCategory_\(UUID().uuidString.prefix(8))"
        sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "original content".write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: categoryFolderURL())
    }

    private func categoryFolderURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Receipts", isDirectory: true)
            .appendingPathComponent(testCategory, isDirectory: true)
    }

    func testImportFileCopiesWhenDestinationAbsent() throws {
        let copied = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")
        XCTAssertTrue(copied)

        let destURL = categoryFolderURL().appendingPathComponent("receipt.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertEqual(try String(contentsOf: destURL, encoding: .utf8), "original content")
    }

    func testImportFileDoesNotOverwriteExistingDestination() throws {
        // First copy establishes the destination — mirrors an entry that
        // already has its file on this phone.
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")

        // A second call for the same destination filename — the exact shape
        // of the photo-reattach change: importFile runs again for an entry
        // already in history, and must be a safe no-op when the file is
        // already there.
        let secondSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "different content".write(to: secondSource, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secondSource) }

        let copied = try LocalReceiptStore.importFile(from: secondSource, category: testCategory, filename: "receipt.txt")
        XCTAssertFalse(copied, "importFile must report false — no copy — when the destination already exists")

        let destURL = categoryFolderURL().appendingPathComponent("receipt.txt")
        XCTAssertEqual(try String(contentsOf: destURL, encoding: .utf8), "original content",
                       "existing file content must be untouched — the property RestoreService's reattach logic relies on")
    }
}
