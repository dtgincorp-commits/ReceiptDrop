import Foundation

/// Merges one category into another — moves every receipt (file + CSV row +
/// Comments) from `source` to `destination` via the same
/// `SubmissionPipeline.updateEntry` path a manual per-receipt category edit
/// already uses, then removes `source` from the category list. Exists to
/// clean up duplicate categories (e.g. a case-mismatched "Sample Category" /
/// "SAMPLE CATEGORY" pair created by an old restore bug — see
/// `CategoryStore.add`), but works for any two categories.
enum CategoryMergeService {
    enum MergeError: LocalizedError {
        case sameCategory
        var errorDescription: String? {
            switch self {
            case .sameCategory: return "Can't merge a category into itself."
            }
        }
    }

    struct MergeSummary {
        var receiptsMoved = 0
        var backupFilename = ""
        /// Suspected duplicates found across the *entire* destination
        /// category after the merge — not just among the newly-moved
        /// entries, since a case-mismatched category split (the bug this
        /// tool exists to clean up) is exactly the kind of thing that can
        /// hide a pre-existing duplicate from the submit-time check, which
        /// compares within one category only. Never auto-resolved — see
        /// `DuplicateReviewView`.
        var duplicatePairs: [DuplicateDetectionService.Pair] = []
    }

    /// Backs up first, and only proceeds if that backup actually succeeds —
    /// same non-negotiable ordering as year/month deletion. `source`'s
    /// now-empty folder and CSV are left on disk rather than deleted; an
    /// empty leftover folder is harmless, whereas deleting the wrong folder
    /// on a bad category-name match would not be.
    static func merge(from source: String, into destination: String) throws -> MergeSummary {
        guard source != destination else { throw MergeError.sameCategory }

        let backupURL = try ArchiveBackupService.buildFullBackup()

        let entries = SubmissionStore.loadHistory().filter { $0.category == source }
        let comments = LocalReceiptStore.commentsByReceipt(categories: [source])

        for entry in entries {
            let key = LocalReceiptStore.commentsKey(
                category: source, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink)
            _ = try SubmissionPipeline.updateEntry(
                old: entry, newCategory: destination, newVendor: entry.vendor,
                newWorkDate: entry.workDate, newAmount: entry.amount,
                newComments: comments[key] ?? "", newVendorType: entry.vendorType)
        }

        CategoryStore.shared.remove(named: source)
        BackupSettings.lastBackupDate = Date()

        let destinationEntries = SubmissionStore.loadHistory().filter { $0.category == destination }
        let duplicatePairs = DuplicateDetectionService.findPairs(in: destinationEntries)

        return MergeSummary(
            receiptsMoved: entries.count, backupFilename: backupURL.lastPathComponent,
            duplicatePairs: duplicatePairs)
    }
}
