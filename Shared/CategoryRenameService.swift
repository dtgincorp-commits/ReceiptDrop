import Foundation

/// Renames a category — moves every receipt (file + CSV row + Comments) from
/// `oldName` to `newName` via the same `SubmissionPipeline.updateEntry` path
/// `CategoryMergeService` uses, then swaps `oldName` for `newName` in the
/// category list. Unlike merge, `newName` must not already exist — renaming
/// into an existing category is what Merge is for, and silently merging
/// instead of renaming would surprise a caller expecting a rename.
enum CategoryRenameService {
    enum RenameError: LocalizedError {
        case emptyName
        case sameName
        case alreadyExists
        var errorDescription: String? {
            switch self {
            case .emptyName: return "Category name can't be empty."
            case .sameName: return "That's already the current name."
            case .alreadyExists: return "A category with that name already exists."
            }
        }
    }

    struct RenameSummary {
        var receiptsRenamed = 0
        var backupFilename = ""
    }

    /// Backs up first, same non-negotiable ordering as merge and year/month
    /// deletion. `oldName`'s now-empty folder and CSV are left on disk
    /// rather than deleted — same reasoning as merge's leftover folder.
    static func rename(_ oldName: String, to newNameRaw: String) throws -> RenameSummary {
        let newName = newNameRaw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !newName.isEmpty else { throw RenameError.emptyName }
        guard newName.caseInsensitiveCompare(oldName) != .orderedSame else { throw RenameError.sameName }
        // Checked up front, before any backup or file move: CategoryStore.add
        // silently no-ops on a duplicate name (by design, for restore's
        // sake), which would otherwise let this proceed, move every receipt
        // to a name that's already in use elsewhere, and then remove
        // `oldName` from the list — quietly merging when the caller asked to
        // rename. That's exactly what CategoryMergeService is for instead.
        guard !CategoryStore.shared.categories.contains(where: { $0.caseInsensitiveCompare(newName) == .orderedSame }) else {
            throw RenameError.alreadyExists
        }

        let backupURL = try ArchiveBackupService.buildFullBackup()

        // Case-insensitive, same reasoning as CategoryMergeService: a
        // receipt's own `category` string can differ in case from the list
        // entry the caller is renaming.
        let entries = SubmissionStore.loadHistory().filter { $0.category.caseInsensitiveCompare(oldName) == .orderedSame }
        let comments = LocalReceiptStore.commentsByReceipt(categories: Array(Set(entries.map(\.category))))

        for entry in entries {
            let key = LocalReceiptStore.commentsKey(
                category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink)
            _ = try SubmissionPipeline.updateEntry(
                old: entry, newCategory: newName, newVendor: entry.vendor,
                newWorkDate: entry.workDate, newAmount: entry.amount,
                newComments: comments[key] ?? "", newVendorType: entry.vendorType)
        }

        // Carry the description across under the new name — a rename is the
        // same category continuing under a new label, not a fresh one.
        let description = CategoryStore.shared.description(for: oldName)
        _ = CategoryStore.shared.add(newName)
        if !description.isEmpty {
            CategoryStore.shared.setDescription(description, for: newName)
        }
        CategoryStore.shared.remove(named: oldName)
        BackupSettings.lastBackupDate = Date()

        return RenameSummary(receiptsRenamed: entries.count, backupFilename: backupURL.lastPathComponent)
    }
}
