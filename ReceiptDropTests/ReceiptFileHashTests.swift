import XCTest
@testable import ReceiptDrop

/// Pins down `ReceiptFileHash`, the content-identity primitive built to fix
/// a real duplicate-detection miss: two Noom receipts, same vendor, same
/// category, identical $5700.00 amount, both with no printed date — each
/// got "defaulted to today" at save time, 36 days apart, which defeated
/// every existing signal (all gate on `workDate`). A hash of the file's
/// bytes has no such blind spot: the same bytes always hash the same, no
/// matter what any AI model reads off the receipt.
///
/// This suite only covers the hashing primitive itself — same bytes hash
/// equal, different bytes hash differently, hashing is stable across calls,
/// and `storedRepresentation` mirrors `LocalReceiptStore.save`'s
/// normalization. The end-to-end regression (two Noom-shaped entries
/// actually getting flagged as duplicates) is covered separately in
/// `DuplicateDetectionIdenticalFileTests`, since that's a
/// `DuplicateDetectionService` behavior, not a hashing one.
final class ReceiptFileHashTests: XCTestCase {
    func testIdenticalBytesHashEqual() {
        let data = Data("this is a receipt".utf8)
        XCTAssertEqual(ReceiptFileHash.hash(of: data), ReceiptFileHash.hash(of: data))
    }

    func testDifferentBytesHashDifferently() {
        let a = Data("receipt A".utf8)
        let b = Data("receipt B".utf8)
        XCTAssertNotEqual(ReceiptFileHash.hash(of: a), ReceiptFileHash.hash(of: b))
    }

    /// Even a single differing byte (as opposed to totally different content)
    /// must not collide — the whole point of using SHA-256 rather than some
    /// cheaper checksum is that near-identical files still diverge.
    func testASingleByteDifferenceChangesTheHash() {
        let a = Data([0x01, 0x02, 0x03])
        let b = Data([0x01, 0x02, 0x04])
        XCTAssertNotEqual(ReceiptFileHash.hash(of: a), ReceiptFileHash.hash(of: b))
    }

    func testHashIsStableAcrossRepeatedCalls() {
        let data = Data("stable input".utf8)
        let first = ReceiptFileHash.hash(of: data)
        for _ in 0..<5 {
            XCTAssertEqual(ReceiptFileHash.hash(of: data), first)
        }
    }

    /// Lowercase hex, fixed length (SHA-256 = 32 bytes = 64 hex chars) —
    /// pinned down because `DuplicateDetectionService`'s grouping and the
    /// backfill's persisted values both depend on the format never
    /// silently changing (e.g. uppercase hex would still be "correct"
    /// cryptographically but would stop matching hashes computed before a
    /// hypothetical future change).
    func testHashFormatIsLowercaseHexOfFixedLength() {
        let hash = ReceiptFileHash.hash(of: Data("anything".utf8))
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertNotNil(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    /// PDFs are never re-encoded (only images go through
    /// `ClaudeService.downscaledJPEG`), so `storedRepresentation` must be a
    /// pure passthrough for `.pdf` — a mismatch here would mean a PDF
    /// hashed at submit time never matches the same PDF hashed later by the
    /// backfill reading it straight off disk.
    func testStoredRepresentationPassesPDFBytesThroughUnchanged() {
        let data = Data("%PDF-1.4 fake pdf bytes".utf8)
        XCTAssertEqual(ReceiptFileHash.storedRepresentation(of: data, kind: .pdf), data)
    }

    /// `hashOfStoredRepresentation` must be exactly
    /// `hash(of: storedRepresentation(...))` — not some independent
    /// computation — since `SubmissionPipeline` calls the convenience
    /// method at submit time while `ReceiptHashBackfillService` hashes
    /// already-stored bytes directly with `hash(of:)`; the two have to
    /// agree for a freshly-submitted receipt's hash to match what the
    /// backfill would compute from its file on disk.
    func testHashOfStoredRepresentationMatchesHashingTheStoredBytesDirectly() {
        let data = Data("%PDF-1.4 another fake pdf".utf8)
        let expected = ReceiptFileHash.hash(of: ReceiptFileHash.storedRepresentation(of: data, kind: .pdf))
        XCTAssertEqual(ReceiptFileHash.hashOfStoredRepresentation(of: data, kind: .pdf), expected)
    }
}
