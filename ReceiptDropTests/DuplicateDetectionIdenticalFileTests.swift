import XCTest
@testable import ReceiptDrop

/// Tests `DuplicateDetectionService`'s highest-confidence signal — two
/// entries with an identical, non-empty `fileHash` — added to close a real
/// gap in every pre-existing signal, all of which gate on `workDate`.
///
/// The motivating bug: two Noom receipts, same vendor, same category,
/// identical $5700.00 amount, neither with a printed date, each "defaulted
/// to today" 36 days apart (2026-07-24 and 2026-08-29). That gap is far
/// outside both `nearbyDateWindow` (3 days) and `tipDateWindow` (14 days),
/// and the amounts are identical rather than tip-shaped, so neither Signal 1
/// (same date+amount) nor Signal 2 (matching vendor + nearby date) could
/// ever have caught it — the two entries simply don't fall into the same
/// bucket by either. Only a signal that ignores date/amount/vendor entirely
/// and looks at the bytes themselves can.
final class DuplicateDetectionIdenticalFileTests: XCTestCase {
    private func makeEntry(vendor: String, workDate: String, amount: String,
                           fileHash: String, timestamp: Date = Date()) -> HistoryEntry {
        HistoryEntry(
            category: "Test", vendor: vendor, workDate: workDate, amount: amount,
            receiptLink: "\(UUID().uuidString).jpg", timestamp: timestamp, fileHash: fileHash)
    }

    /// The bug this feature exists to fix, named so that's unmistakable:
    /// two Noom receipts, 36 days apart, same vendor/amount, identical
    /// fileHash — must now be detected, where before this signal existed
    /// nothing caught it at all.
    func testNoomReceiptsThirtySixDaysApartAreDetectedAsDuplicatesViaIdenticalFileHash() {
        let sharedHash = ReceiptFileHash.hash(of: Data("noom-receipt-bytes".utf8))
        let first = makeEntry(vendor: "Noom", workDate: "2026-07-24", amount: "5700.00", fileHash: sharedHash)
        let second = makeEntry(vendor: "Noom", workDate: "2026-08-29", amount: "5700.00", fileHash: sharedHash)

        let pairs = DuplicateDetectionService.findPairs(in: [first, second])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .identicalFile)
    }

    /// The hash alone is sufficient — it doesn't need vendor or amount to
    /// also agree, because two entries with the same fileHash are, by
    /// construction, the same file. (In practice a re-submission of the
    /// same bytes would usually keep the same AI-extracted vendor/amount
    /// too, but the signal must not depend on that.)
    func testIdenticalFileHashIsSufficientEvenWithDifferentVendorAndAmount() {
        let sharedHash = ReceiptFileHash.hash(of: Data("some-shared-file".utf8))
        let first = makeEntry(vendor: "Home Depot", workDate: "2026-06-01", amount: "12.34", fileHash: sharedHash)
        let second = makeEntry(vendor: "Totally Different Vendor Inc", workDate: "2026-08-15", amount: "999.99", fileHash: sharedHash)

        let pairs = DuplicateDetectionService.findPairs(in: [first, second])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .identicalFile)
    }

    /// Empty `fileHash` means "not yet hashed" — every manual entry and
    /// every pre-existing receipt not yet backfilled shares that same empty
    /// string. If empty strings were allowed to match each other, every
    /// legacy entry in a user's history would pair up with every other
    /// legacy entry, which would flood the duplicate review screen with
    /// noise. The signal must require a real, non-empty hash on both sides.
    func testEntriesWithEmptyFileHashAreNeverPairedByThisSignal() {
        let a = makeEntry(vendor: "Vendor A", workDate: "2026-01-01", amount: "10.00", fileHash: "")
        let b = makeEntry(vendor: "Vendor B", workDate: "2026-01-02", amount: "20.00", fileHash: "")
        let c = makeEntry(vendor: "Vendor C", workDate: "2026-01-03", amount: "30.00", fileHash: "")

        let pairs = DuplicateDetectionService.findPairs(in: [a, b, c])

        XCTAssertTrue(pairs.allSatisfy { $0.confidence != .identicalFile })
    }

    /// A pair that the hash signal catches AND that also happens to satisfy
    /// an older signal (same date, same amount) must appear exactly once —
    /// not once per signal that would have matched it.
    func testAPairCaughtByTheHashSignalAppearsExactlyOnceEvenWhenOtherSignalsWouldAlsoMatch() {
        let sharedHash = ReceiptFileHash.hash(of: Data("same-day-rescan".utf8))
        let first = makeEntry(vendor: "Shell", workDate: "2026-05-01", amount: "45.00", fileHash: sharedHash)
        let second = makeEntry(vendor: "Shell", workDate: "2026-05-01", amount: "45.00", fileHash: sharedHash)

        let pairs = DuplicateDetectionService.findPairs(in: [first, second])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .identicalFile)
    }

    /// `.identicalFile` must sort strictly above `.likely` — the highest
    /// confidence signal has to actually surface first on the duplicate
    /// review screen, not just exist as a case nobody sees ranked.
    func testIdenticalFileConfidenceSortsAboveLikely() {
        let sharedHash = ReceiptFileHash.hash(of: Data("hashed-pair".utf8))
        // A same-vendor pair with no shared date/amount/hash, so it only
        // ever qualifies for `.likely` via the makePair() same-date+amount
        // grouping bucket below.
        let likelyA = makeEntry(vendor: "Costco", workDate: "2026-03-01", amount: "88.88", fileHash: "")
        let likelyB = makeEntry(vendor: "Costco", workDate: "2026-03-01", amount: "88.88", fileHash: "")
        let hashedA = makeEntry(vendor: "Walgreens", workDate: "2026-04-01", amount: "5.00", fileHash: sharedHash)
        let hashedB = makeEntry(vendor: "Walgreens", workDate: "2026-06-01", amount: "5.00", fileHash: sharedHash)

        let pairs = DuplicateDetectionService.findPairs(in: [likelyA, likelyB, hashedA, hashedB])

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first?.confidence, .identicalFile)
        XCTAssertEqual(pairs.last?.confidence, .likely)
    }
}
