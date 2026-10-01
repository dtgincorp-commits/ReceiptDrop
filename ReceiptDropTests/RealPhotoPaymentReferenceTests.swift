import XCTest
@testable import ReceiptDrop

/// Runs real payment screenshots through the same code the app uses —
/// Vision OCR included — rather than through pre-typed OCR text.
///
/// The photos are personal payment records, so they are never committed:
/// they live in `test-receipts/zelle/` (git-ignored, like the rest of
/// `test-receipts/`) next to `expected_references.csv` listing each file's
/// correct references. Where that folder is absent — another checkout,
/// Xcode Cloud — the test skips rather than fails.
///
/// To add a case: drop the photo in that folder and add a CSV line,
/// separating several references with ";".
final class RealPhotoPaymentReferenceTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-receipts/zelle")
    }

    private func loadExpected() throws -> [(file: String, references: Set<String>)] {
        let csv = fixtures.appendingPathComponent("expected_references.csv")
        guard FileManager.default.fileExists(atPath: csv.path) else {
            throw XCTSkip("No local payment screenshots in test-receipts/zelle/")
        }
        return try String(contentsOf: csv).split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], Set(parts[1].split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }))
        }
    }

    func testEveryPhotoReadsExactlyItsReferences() async throws {
        let category = "RealPhotoTest_\(UUID().uuidString.prefix(6))"
        var entries: [HistoryEntry] = []
        defer { removeCategoryFolder(category, entries) }

        for (file, expected) in try loadExpected() {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(file))
            let stored = try LocalReceiptStore.save(data: data, category: category, kind: .image)
            let entry = HistoryEntry(category: category, vendor: "ZELLE TO SAME PERSON",
                                     workDate: "2025-02-04", amount: "50.00",
                                     receiptLink: stored, timestamp: Date())
            entries.append(entry)
            let read = await PaymentReference.read(for: entry)
            XCTAssertEqual(read, expected, file)
        }

        // The hardest case: every receipt made to look like the same vendor,
        // same day, same amount. Only the references can tell them apart.
        let suspected = DuplicateDetectionService.findGroups(in: entries)
        XCTAssertFalse(suspected.isEmpty, "the setup must actually look like duplicates")
        let settled = await PaymentReference.excludingDifferentPayments(suspected)
        XCTAssertTrue(settled.isEmpty, "every one of these is a different payment")
    }

    func testTheSamePhotoSavedTwiceStaysADuplicate() async throws {
        // Not `XCTUnwrap(try loadExpected().first)`: a skip thrown inside
        // XCTUnwrap's argument is reported as a failure, not a skip.
        let expected = try loadExpected()
        let first = try XCTUnwrap(expected.first)
        let category = "RealPhotoTest_\(UUID().uuidString.prefix(6))"
        let data = try Data(contentsOf: fixtures.appendingPathComponent(first.file))
        let entries = try (0..<2).map { _ in
            HistoryEntry(category: category, vendor: "X", workDate: "2025-01-01", amount: "1.00",
                         receiptLink: try LocalReceiptStore.save(data: data, category: category, kind: .image),
                         timestamp: Date())
        }
        defer { removeCategoryFolder(category, entries) }

        let settled = await PaymentReference.excludingDifferentPayments(
            DuplicateDetectionService.findGroups(in: entries))

        XCTAssertEqual(settled.count, 1)
    }

    private func removeCategoryFolder(_ category: String, _ entries: [HistoryEntry]) {
        guard let entry = entries.first,
              let url = LocalReceiptStore.existingFileURL(category: category, filename: entry.receiptLink)
        else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
