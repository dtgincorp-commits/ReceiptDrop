import Foundation

/// Deletes a category *and* every receipt in it — file, CSV row, and history
/// entry — then removes the category from the list.
///
/// Deliberately separate from `CategoryStore.remove`, which only drops the
/// name and description and leaves every receipt untouched. That's the safe
/// default and stays the default, but it surprised at least one user who
/// deleted a category expecting its receipts to go with it, then recreated
/// the category and found them all still there (they had never left history
/// — only the filter pill had gone, orphaning them under "All"). Both
/// intents are real; this type covers the destructive one so the UI can
/// offer it explicitly rather than leaving the user to guess which one
/// deletion means.
enum CategoryDeleteService {
    struct DeleteSummary {
        var receiptsDeleted = 0
        var backupFilename = ""
    }

    /// Backs up first, and only proceeds if that backup actually succeeds —
    /// same non-negotiable ordering as merge, rename, and year/month
    /// deletion. The category's now-empty folder and CSV are left on disk,
    /// matching merge's reasoning: an empty leftover folder is harmless,
    /// whereas deleting the wrong folder on a bad name match would not be.
    static func deleteWithReceipts(_ category: String) throws -> DeleteSummary {
        let backupURL = try ArchiveBackupService.buildFullBackup()

        // Case-insensitive, same as merge/rename: a receipt's own `category`
        // string can differ in case from the list entry being deleted (see
        // CategoryStore.add). An exact match here would leave exactly the
        // mixed-case receipts behind that the user just asked to delete.
        let entries = SubmissionStore.loadHistory()
            .filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }

        for entry in entries {
            SubmissionStore.removeHistory(entry)
            // Keyed off `entry.category`, not `category` — the CSV and files
            // live under whatever name the receipt actually carries.
            try? LocalReceiptStore.deleteEntry(
                category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
        }

        CategoryStore.shared.remove(named: category)
        BackupSettings.lastBackupDate = Date()

        return DeleteSummary(receiptsDeleted: entries.count, backupFilename: backupURL.lastPathComponent)
    }
}
