import Foundation
import CryptoKit

/// Content-identity hashing for receipt files — the piece the app never had
/// before this was added. Every existing duplicate signal
/// (`SubmissionPipeline`'s submit-time check, `DuplicateDetectionService`'s
/// review-screen signals) gates on `workDate`, which is AI-extracted and
/// non-deterministic: the same physical receipt, submitted twice, can come
/// back with two different dates. Confirmed real case — a Noom receipt with
/// no printed date got "defaulted to today" on both scans, 36 days apart,
/// which sailed past every date-based check because the two dates genuinely
/// disagreed. A hash of the bytes themselves has no such failure mode: the
/// same file always hashes the same, independent of what any model reads
/// off it.
///
/// `hash(of:)` is the primitive; everything else here is about hashing the
/// right bytes. `LocalReceiptStore.save` doesn't store what it's handed —
/// for images it stores `ClaudeService.downscaledJPEG(from: data) ?? data`,
/// re-encoding anything above 1568px and passing anything already at or
/// under that size through untouched. Two submissions of the identical
/// photo only produce identical stored bytes if they're hashed *after* that
/// normalization; hashing the raw incoming bytes would make two really-
/// identical files disagree whenever the re-encode path fires on one call
/// but not the other (e.g. the same photo re-compressed slightly differently
/// by two different share-sheet senders before either one ever reaches this
/// app). Hashing the stored form is also what makes the backfill in
/// `ReceiptHashBackfillService` possible at all: it can only ever read what's
/// sitting on disk, which is already in stored form, so the same
/// normalization has to be the one both call sites agree on.
///
/// Known caveat, deliberately accepted: ImageIO's JPEG encoder is
/// deterministic for a given input on a given OS/hardware combination, but
/// isn't a documented cross-version guarantee — a future OS could change
/// its encoder and produce different bytes for the same source image than
/// today's OS does. If that ever happens, an old hash (computed under the
/// old OS) stops matching a new one (computed under the new OS) for what is
/// still, physically, the same receipt. The failure direction only ever
/// runs one way: a missed duplicate, never a false one — two different
/// receipts can't collide into the same hash just because an encoder
/// changed. And it's fully recoverable: re-running the backfill re-hashes
/// every stored file under whatever encoder is current, so the fix is a
/// button tap, not a data-loss event.
enum ReceiptFileHash {
    /// SHA-256 of `data`, lowercase hex. No normalization — callers that
    /// need the stored-file normalization use `storedRepresentation(of:kind:)`
    /// first.
    static func hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Mirrors `LocalReceiptStore.save`'s exact normalization — the bytes
    /// this returns are byte-for-byte what ends up written to disk for a
    /// given `(data, kind)` pair. Kept in lockstep deliberately: this
    /// function and `LocalReceiptStore.save` must never diverge, or a
    /// freshly-submitted receipt's hash would stop matching the hash the
    /// backfill computes from that same receipt's file on disk.
    static func storedRepresentation(of data: Data, kind: ReceiptKind) -> Data {
        kind == .image ? (ClaudeService.downscaledJPEG(from: data) ?? data) : data
    }

    /// Convenience for the common case: normalize then hash, in one call —
    /// what `SubmissionPipeline` uses at submit time, before the file is
    /// ever written.
    static func hashOfStoredRepresentation(of data: Data, kind: ReceiptKind) -> String {
        hash(of: storedRepresentation(of: data, kind: kind))
    }
}
