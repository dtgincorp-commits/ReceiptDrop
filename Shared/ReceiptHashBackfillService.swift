import Foundation

/// One-time (re-runnable) maintenance action: computes `HistoryEntry.fileHash`
/// for every entry that predates the field, so `DuplicateDetectionService`'s
/// identical-file signal (and `SubmissionPipeline`'s submit-time check) can
/// catch duplicates among receipts that were already on the phone before
/// hashing existed — mirrors `VendorTypeBackfillService`, which does the same
/// one-time sweep for `vendorType`.
///
/// Reads each entry's file straight off disk rather than re-deriving
/// anything: `LocalReceiptStore.existingFileURL` finds it under
/// `entry.category`/`entry.receiptLink`, and the bytes there are ALREADY in
/// stored form — `LocalReceiptStore.save` normalized them (downscaled to a
/// JPEG, or left as-is) the moment the receipt was first saved. Re-running
/// `ReceiptFileHash.storedRepresentation` on top of an already-stored file
/// would be redundant at best, and actively wrong if the file happens to be
/// a PDF or an already-small JPEG that `downscaledJPEG` would try (and fail)
/// to reprocess — so this hashes the on-disk bytes exactly as they sit,
/// via `ReceiptFileHash.hash(of:)` directly, never `storedRepresentation`.
enum ReceiptHashBackfillService {
    /// Guards against a second sweep starting while one is still running —
    /// `scenePhase` goes `.active` on every foreground, not just launch, so
    /// `runOnForeground()` can genuinely be called again mid-run (background
    /// the app during a long first sweep, come straight back). Two concurrent
    /// sweeps would both read the same history, both hash the same files, and
    /// race each other's `updateHistoryEntries` write. `@MainActor` rather
    /// than a lock because every read and write of it happens there.
    @MainActor private static var isRunning = false

    /// Fire-and-forget sweep for app launch/foreground — the reason there is
    /// no button for this in Settings.
    ///
    /// A manual control was the first version and was wrong: `backfill()`
    /// skips any entry that already has a hash, and every new receipt is
    /// hashed at save time by `SubmissionPipeline`, so after a single run the
    /// button could only ever report "nothing to fingerprint" forever. That
    /// framed a self-healing internal detail as a chore the user was supposed
    /// to remember. It isn't one — the only states that produce unhashed
    /// entries (a restore from a backup made before the field existed, a
    /// file that reappears after being unreachable) are exactly the states
    /// this catches on the next foreground, with nobody having to know.
    ///
    /// Deliberately silent: no progress, no completion message, no error
    /// surface. Nothing here is a user-visible feature — the observable
    /// effect is duplicates simply being found — and a failure just means
    /// entries stay unhashed and get another attempt next foreground.
    @MainActor
    static func runOnForeground() {
        guard !isRunning else { return }
        isRunning = true
        // `.utility`, not `.userInitiated`: nobody is waiting on this, and it
        // competes with first paint on launch. It walks the whole history and
        // reads a file per entry, which is instant at 47 receipts and is not
        // at a few thousand — that cost belongs off the main thread and below
        // the work the user can actually see.
        Task.detached(priority: .utility) {
            backfill()
            await MainActor.run { isRunning = false }
        }
    }

    /// Skips: entries with no file at all (`manualEntryLabel`/
    /// `scannedTextLabel` placeholders), entries whose file can't be found
    /// on disk (moved/deleted since, or an in-flight spool item), and
    /// entries that already have a hash (nothing to redo). Safe to run
    /// repeatedly — a second run touches zero entries once the first has
    /// caught everything reachable.
    @discardableResult
    static func backfill() -> Int {
        let history = SubmissionStore.loadHistory()
        var updates: [HistoryEntry] = []

        for entry in history {
            guard entry.fileHash.isEmpty else { continue }
            guard !entry.receiptLink.isEmpty, !SubmissionPipeline.isPlaceholderLabel(entry.receiptLink) else { continue }
            guard let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink),
                  let data = try? Data(contentsOf: url) else { continue }

            var updated = entry
            updated.fileHash = ReceiptFileHash.hash(of: data)
            updates.append(updated)
        }

        return SubmissionStore.updateHistoryEntries(updates)
    }
}
