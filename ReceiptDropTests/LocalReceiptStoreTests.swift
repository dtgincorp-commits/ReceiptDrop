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
    private var destCategory: String!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        testCategory = "TestCategory_\(UUID().uuidString.prefix(8))"
        destCategory = "DestCategory_\(UUID().uuidString.prefix(8))"
        sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "original content".write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: categoryFolderURL())
        try? FileManager.default.removeItem(at: categoryFolderURL(destCategory))
    }

    private func categoryFolderURL() -> URL { categoryFolderURL(testCategory) }

    private func categoryFolderURL(_ category: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Receipts", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
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

    // MARK: - moveFile collision handling
    //
    // A receipt's filename is stamped with the category it was created in and
    // never renamed afterward, so a file that has moved categories keeps a
    // name that "belongs" somewhere else. If anything copies that file back
    // into its original category without the entry pointing there (a restore
    // writing to a stale category did exactly this), the orphan left behind
    // permanently blocks the user from moving the real receipt back — the
    // move fails with "an item with the same name already exists" every time.

    func testMoveFileReconcilesIdenticalOrphanAtDestination() throws {
        // The real shape of the bug: the same file exists in both the source
        // category (where the entry actually lives) and the destination
        // (an orphaned copy nothing points at).
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: destCategory, filename: "receipt.txt")

        // Must not throw — identical contents mean the destination copy is
        // already the right one, so the move is effectively already done.
        try LocalReceiptStore.moveFile(filename: "receipt.txt", from: testCategory, to: destCategory)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: categoryFolderURL().appendingPathComponent("receipt.txt").path),
            "the redundant source copy should be cleaned up, not left behind as a second orphan")
        let destURL = categoryFolderURL(destCategory).appendingPathComponent("receipt.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertEqual(try String(contentsOf: destURL, encoding: .utf8), "original content")
    }

    func testMoveFileThrowsOnDifferentContentsAtDestination() throws {
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")

        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "genuinely different receipt".write(to: otherURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: otherURL) }
        _ = try LocalReceiptStore.importFile(from: otherURL, category: destCategory, filename: "receipt.txt")

        // Two different files under one name is a real anomaly — surface it
        // rather than silently overwriting what might be the only copy of
        // someone's receipt.
        XCTAssertThrowsError(
            try LocalReceiptStore.moveFile(filename: "receipt.txt", from: testCategory, to: destCategory))

        XCTAssertEqual(
            try String(contentsOf: categoryFolderURL(destCategory).appendingPathComponent("receipt.txt"), encoding: .utf8),
            "genuinely different receipt", "destination must be left untouched when the move is refused")
    }

    func testMoveFileMovesWhenDestinationIsEmpty() throws {
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")

        try LocalReceiptStore.moveFile(filename: "receipt.txt", from: testCategory, to: destCategory)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: categoryFolderURL().appendingPathComponent("receipt.txt").path))
        XCTAssertEqual(
            try String(contentsOf: categoryFolderURL(destCategory).appendingPathComponent("receipt.txt"), encoding: .utf8),
            "original content")
    }
}
