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

    // MARK: - Case-insensitive folder resolution
    //
    // iOS's data volume is case-sensitive, so "Sample Category" and "SAMPLE
    // CATEGORY" are two different directories to the filesystem even though
    // CategoryStore treats them as one category (see CategoryStore.add).
    // Every folder-path build in LocalReceiptStore routes through
    // `categoryFolderURL`, which resolves a category name against whatever
    // already exists on disk before appending it — these tests cover that
    // resolution directly, plus the `healCaseVariantCategoryFolders` cleanup
    // for installs that already have the split.

    func testImportFileReusesExistingCaseVariantFolderInsteadOfSplitting() throws {
        _ = try LocalReceiptStore.importFile(from: sourceURL, category: testCategory, filename: "receipt.txt")

        let differentCase = testCategory.uppercased()
        XCTAssertNotEqual(differentCase, testCategory, "the two spellings must actually differ for this test to mean anything")
        defer { try? FileManager.default.removeItem(at: categoryFolderURL(differentCase)) }

        let secondSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "second file".write(to: secondSource, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secondSource) }

        _ = try LocalReceiptStore.importFile(from: secondSource, category: differentCase, filename: "second.txt")

        // Both files must land under the one folder that already existed
        // (testCategory's original spelling) — not a second sibling folder
        // for the differently-cased name.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: categoryFolderURL().appendingPathComponent("second.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: categoryFolderURL(differentCase).path))
    }

    // `healCaseVariantCategoryFolders`'s production trigger is two folders
    // that differ only by case (e.g. "Sample Category" / "SAMPLE
    // CATEGORY") — real on a device's case-sensitive data volume, but the
    // Mac this test runs on formats its own filesystem case-insensitively,
    // so `mkdir` for the second spelling silently collapses onto the first
    // rather than creating a second folder (confirmed independently: two
    // `FileManager.createDirectory` calls for case-variant names throw an
    // I/O error here, the case-insensitive volume treating them as the same
    // path). These tests instead call `mergeFolderContents` — the exact
    // function `healCaseVariantCategoryFolders` calls per variant it
    // finds — directly on two ordinarily-named folders, which exercises
    // the identical move/reconcile/CSV-merge logic without depending on
    // case-variant folders actually existing on disk.

    func testMergeFolderContentsMovesFilesAndCSVLogs() throws {
        let sourceFolder = categoryFolderURL(testCategory)
        let destFolder = categoryFolderURL(destCategory)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        try "source content".write(to: sourceFolder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "dest content".write(to: destFolder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let header = "Contractor_or_Vendor_Name,Work_Date,Amount,Comments,Receipt_File,Scanned_Date\n"
        try (header + "Vendor A,2024-01-01,10.00,,a.txt,2024-01-01\n")
            .write(to: sourceFolder.appendingPathComponent("\(testCategory!)_log.csv"), atomically: true, encoding: .utf8)
        try (header + "Vendor B,2024-01-02,20.00,,b.txt,2024-01-02\n")
            .write(to: destFolder.appendingPathComponent("\(destCategory!)_log.csv"), atomically: true, encoding: .utf8)

        let result = LocalReceiptStore.mergeFolderContents(from: sourceFolder, into: destFolder)

        XCTAssertEqual(result.conflicted, 0)
        XCTAssertGreaterThanOrEqual(result.moved, 2) // a.txt + the CSV

        // The source folder is fully consolidated away; dest holds everything.
        XCTAssertFalse(fm.fileExists(atPath: sourceFolder.path))
        XCTAssertTrue(fm.fileExists(atPath: destFolder.appendingPathComponent("a.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: destFolder.appendingPathComponent("b.txt").path))

        // The CSV merges under dest's own log filename, not source's —
        // otherwise the two categories' differently-named logs would both
        // end up sitting in dest instead of merging into one.
        let mergedCSVURL = destFolder.appendingPathComponent("\(destCategory!)_log.csv")
        let mergedCSV = try String(contentsOf: mergedCSVURL, encoding: .utf8)
        XCTAssertTrue(mergedCSV.contains("Vendor A"))
        XCTAssertTrue(mergedCSV.contains("Vendor B"))
        XCTAssertEqual(mergedCSV.components(separatedBy: "Contractor_or_Vendor_Name").count - 1, 1,
                       "header must not be duplicated by the merge")
        XCTAssertFalse(fm.fileExists(atPath: destFolder.appendingPathComponent("\(testCategory!)_log.csv").path),
                       "source's own (differently-named) CSV must not be left behind alongside the merged one")
    }

    func testMergeFolderContentsReconcilesIdenticalSameNamedFile() throws {
        let sourceFolder = categoryFolderURL(testCategory)
        let destFolder = categoryFolderURL(destCategory)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        try "same content".write(to: sourceFolder.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)
        try "same content".write(to: destFolder.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)

        let result = LocalReceiptStore.mergeFolderContents(from: sourceFolder, into: destFolder)

        XCTAssertEqual(result.conflicted, 0, "identical contents under the same name must reconcile, not conflict")
        XCTAssertFalse(fm.fileExists(atPath: sourceFolder.path), "the redundant source copy/folder should be cleaned up")
        XCTAssertEqual(
            try String(contentsOf: destFolder.appendingPathComponent("receipt.txt"), encoding: .utf8),
            "same content")
    }

    func testMergeFolderContentsLeavesGenuineConflictInPlace() throws {
        let sourceFolder = categoryFolderURL(testCategory)
        let destFolder = categoryFolderURL(destCategory)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        try "source's receipt".write(to: sourceFolder.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)
        try "dest's receipt".write(to: destFolder.appendingPathComponent("receipt.txt"), atomically: true, encoding: .utf8)

        let result = LocalReceiptStore.mergeFolderContents(from: sourceFolder, into: destFolder)

        XCTAssertEqual(result.conflicted, 1, "genuinely different contents under the same name must be surfaced, not silently resolved")
        // Neither copy is lost: source survives (non-empty, so not deleted)
        // and both files keep their own content.
        XCTAssertTrue(fm.fileExists(atPath: sourceFolder.appendingPathComponent("receipt.txt").path))
        XCTAssertEqual(
            try String(contentsOf: sourceFolder.appendingPathComponent("receipt.txt"), encoding: .utf8),
            "source's receipt")
        XCTAssertEqual(
            try String(contentsOf: destFolder.appendingPathComponent("receipt.txt"), encoding: .utf8),
            "dest's receipt")
    }

    func testMergeFolderContentsIsIdempotent() throws {
        let sourceFolder = categoryFolderURL(testCategory)
        let destFolder = categoryFolderURL(destCategory)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try "content".write(to: sourceFolder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let first = LocalReceiptStore.mergeFolderContents(from: sourceFolder, into: destFolder)
        XCTAssertEqual(first.moved, 1)
        XCTAssertFalse(fm.fileExists(atPath: sourceFolder.path))

        // Running again against the now-gone source must be a safe no-op,
        // not an error and not a second move of anything.
        let second = LocalReceiptStore.mergeFolderContents(from: sourceFolder, into: destFolder)
        XCTAssertEqual(second.moved, 0)
        XCTAssertEqual(second.conflicted, 0)
        XCTAssertEqual(
            try String(contentsOf: destFolder.appendingPathComponent("a.txt"), encoding: .utf8),
            "content")
    }

    func testHealCaseVariantCategoryFoldersIsNoOpWithoutDuplicates() {
        // No pre-existing split for this (unique, freshly-generated)
        // category — the common case on every launch after the first.
        let summary = LocalReceiptStore.healCaseVariantCategoryFolders()
        // Can't assert `categoriesHealed == 0` globally (other categories
        // on this shared Documents directory are outside this test's
        // control), only that this call completes without ever touching
        // this test's own (untouched) folder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: categoryFolderURL().path))
        _ = summary
    }
}
