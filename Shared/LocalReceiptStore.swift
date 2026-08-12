import Compression
import Foundation

/// Saves receipts locally instead of to Google Drive/Sheets: each category
/// gets its own folder plus a CSV log inside it, both visible in the Files
/// app under "On My iPhone > ReceiptDrop" (the main app enables file sharing
/// in Info.plist).
///
/// The share extension's sandbox can't write into the main app's Documents
/// directory, so all writes go through the App Group container's spool
/// (Receipts/<CATEGORY>/…), and the main app drains that spool into its own
/// Documents/Receipts/<CATEGORY>/ whenever it becomes active. NSFileCoordinator
/// guards the CSV against interleaved appends between the extension and a
/// simultaneous drain.
enum LocalReceiptStore {
    private static let receiptsDirName = "Receipts"
    private static let backupsDirName = "Backups"

    /// Saves `data` into the App Group spool for `category`, returning the
    /// filename used (also the name the file will keep once drained).
    ///
    /// Photos are stored downscaled to 1568px on the long edge (~10× smaller
    /// than a full camera shot) — receipts only need to stay legible, and this
    /// keeps the app's storage from growing ~1GB/year. Same limit Claude reads
    /// them at, so extraction quality is unaffected. PDFs are stored as-is.
    static func save(data: Data, category: String, kind: ReceiptKind) throws -> String {
        let folder = try spoolCategoryFolder(category)
        let name = fileName(category: category, kind: kind)
        let stored = kind == .image ? (ClaudeService.downscaledJPEG(from: data) ?? data) : data
        try stored.write(to: folder.appendingPathComponent(name))
        return name
    }

    /// Appends a row to the category's CSV log in the spool, writing the
    /// header first if the file doesn't exist yet. `scannedDate` is today's
    /// date (when the receipt was scanned/entered), separate from `workDate`
    /// (the date printed on the receipt itself).
    static func appendLog(vendor: String, workDate: String, amount: String,
                          comments: String, receiptFilename: String, category: String,
                          scannedDate: String = LocalReceiptStore.todayString()) throws {
        let folder = try spoolCategoryFolder(category)
        let csvURL = folder.appendingPathComponent(logFileName(category: category))
        let row = csvRow([vendor, workDate, amount, comments, receiptFilename, scannedDate])

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: csvURL, options: .forMerging, error: &coordinatorError) { url in
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    let header = csvRow(AppConstants.sheetHeader)
                    try (header + row).write(to: url, atomically: true, encoding: .utf8)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    if let data = row.data(using: .utf8) { handle.write(data) }
                }
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Moves every spooled category folder's contents into the main app's
    /// Documents directory (visible in Files), merging with what's already
    /// there. Safe to call repeatedly; already-drained files are skipped.
    static func drainSpoolIntoDocuments() {
        guard let spoolRoot = spoolRootURL(),
              let docsRoot = documentsRootURL() else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: docsRoot, withIntermediateDirectories: true)

        guard let categoryDirs = try? fm.contentsOfDirectory(
            at: spoolRoot, includingPropertiesForKeys: nil) else { return }

        for categoryDir in categoryDirs where categoryDir.hasDirectoryPath {
            let destCategoryDir = docsRoot.appendingPathComponent(categoryDir.lastPathComponent, isDirectory: true)
            try? fm.createDirectory(at: destCategoryDir, withIntermediateDirectories: true)

            guard let files = try? fm.contentsOfDirectory(at: categoryDir, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let dest = destCategoryDir.appendingPathComponent(file.lastPathComponent)
                if file.lastPathComponent.hasSuffix(".csv") {
                    mergeCSV(from: file, into: dest)
                    try? fm.removeItem(at: file)
                } else if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                } else {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// Appends any spooled CSV rows (past the header) onto the existing
    /// Documents CSV, or moves the file over if there's nothing there yet.
    private static func mergeCSV(from spooled: URL, into dest: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else {
            try? fm.moveItem(at: spooled, to: dest)
            return
        }
        guard let spooledText = try? String(contentsOf: spooled, encoding: .utf8) else { return }
        let lines = spooledText.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return } // header only, nothing new
        let rows = lines.dropFirst().joined(separator: "\n") + "\n"

        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: dest, options: .forMerging, error: &coordinatorError) { url in
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = rows.data(using: .utf8) { handle.write(data) }
        }
    }

    // MARK: - Paths

    private static func spoolRootURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)?
            .appendingPathComponent(receiptsDirName, isDirectory: true)
    }

    private static func spoolCategoryFolder(_ category: String) throws -> URL {
        guard let root = spoolRootURL() else {
            throw LocalStoreError.appGroupUnavailable
        }
        let folder = root.appendingPathComponent(category, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The main app's Documents/Receipts directory — visible in the Files app.
    private static func documentsRootURL() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent(receiptsDirName, isDirectory: true)
    }

    /// Marks the receipt storage roots (the app's Documents/Receipts folder and
    /// the App Group spool) as excluded from iCloud/iTunes device backups, so
    /// receipt images never leave the phone via a system backup. Excluding a
    /// directory covers everything inside it, including future files. Safe to
    /// call repeatedly — call it on every launch so the flag survives folders
    /// being recreated. Returns true if at least one root was flagged.
    ///
    /// This is a fixed privacy stance, not a setting: Backup zips (a sibling
    /// `Documents/Backups` folder, not excluded) already ride along in
    /// iCloud and — since `BackupSettings.isAutoBackupDue()` was fixed to
    /// bootstrap itself — get created automatically, so there's already a
    /// recovery path for a lost phone without also putting every receipt
    /// image (redundantly) into iCloud.
    @discardableResult
    static func excludeReceiptsFromBackup() -> Bool {
        let roots = [documentsRootURL(), spoolRootURL()].compactMap { $0 }
        var anyFlagged = false
        for var root in roots {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            if (try? root.setResourceValues(values)) != nil {
                anyFlagged = true
            }
        }
        return anyFlagged
    }

    /// Locates a saved receipt file for preview. Checks Documents (where
    /// drained files live, visible in Files) first, then falls back to the
    /// App Group spool in case a share-extension submission hasn't been
    /// drained yet (the app hasn't been opened since).
    static func existingFileURL(category: String, filename: String) -> URL? {
        if let docURL = documentsRootURL()?
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(filename),
           FileManager.default.fileExists(atPath: docURL.path) {
            return docURL
        }
        if let spoolURL = spoolRootURL()?
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(filename),
           FileManager.default.fileExists(atPath: spoolURL.path) {
            return spoolURL
        }
        return nil
    }

    /// Removes a history entry's row from its category's CSV log and deletes
    /// its underlying file (if any). Called from the main app when the user
    /// deletes a receipt from the Receipts screen.
    static func deleteEntry(category: String, vendor: String, workDate: String,
                            amount: String, receiptFilename: String, extraFiles: [String] = []) throws {
        try removeRow(category: category, vendor: vendor, workDate: workDate,
                      amount: amount, receiptFilename: receiptFilename)

        if !receiptFilename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(receiptFilename),
           let fileURL = existingFileURL(category: category, filename: receiptFilename) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        for extra in extraFiles {
            if let extraURL = existingFileURL(category: category, filename: extra) {
                try? FileManager.default.removeItem(at: extraURL)
            }
        }
    }

    /// Removes just the matching CSV row, leaving any underlying file alone —
    /// used by `deleteEntry` (which also deletes the file) and by edits
    /// (which may move/replace the file separately, or keep it as-is).
    static func removeRow(category: String, vendor: String, workDate: String,
                          amount: String, receiptFilename: String) throws {
        guard let csvURL = existingLogURL(category: category) else { return }

        var coordinatorError: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: csvURL, options: .forMerging, error: &coordinatorError) { url in
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                guard let header = lines.first else { return }
                let remaining = lines.dropFirst().filter { line in
                    let fields = parseCSVLine(line)
                    // fields: [vendor, workDate, amount, comments, receiptFilename, scannedDate]
                    guard fields.count >= 5 else { return true }
                    let matches = fields[0] == vendor && fields[1] == workDate
                        && fields[2] == amount && fields[4] == receiptFilename
                    return !matches
                }
                let newContent = ([String(header)] + remaining.map(String.init))
                    .joined(separator: "\n") + "\n"
                try newContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                thrownError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
    }

    /// Looks up the Comments field for a CSV row matching the given fields —
    /// `HistoryEntry` doesn't carry comments itself, only the CSV does, so
    /// editing a receipt needs to read them back out first to prefill the form.
    static func comments(category: String, vendor: String, workDate: String,
                        amount: String, receiptFilename: String) -> String {
        guard let csvURL = existingLogURL(category: category),
              let text = try? String(contentsOf: csvURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }
            if fields[0] == vendor, fields[1] == workDate, fields[2] == amount, fields[4] == receiptFilename {
                return fields[3]
            }
        }
        return ""
    }

    /// One-pass Comments lookup for the Receipts list's per-receipt summary
    /// line: parses each category's CSV once and returns every row's Comments,
    /// keyed by the same fields `comments(category:...)` matches on. Loading
    /// the whole map on reload is what makes showing a summary under every
    /// row affordable — the alternative (a lookup per visible row) re-reads
    /// and re-parses the same CSV once per receipt.
    static func commentsByReceipt(categories: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for category in categories {
            guard let csvURL = existingLogURL(category: category),
                  let text = try? String(contentsOf: csvURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
                let fields = parseCSVLine(line)
                // fields: [vendor, workDate, amount, comments, receiptFilename, scannedDate]
                guard fields.count >= 5, !fields[3].isEmpty else { continue }
                map[commentsKey(category: category, vendor: fields[0], workDate: fields[1],
                                amount: fields[2], receiptFilename: fields[4])] = fields[3]
            }
        }
        return map
    }

    /// Key for `commentsByReceipt` lookups. Uses the ASCII unit separator so
    /// field values containing commas or pipes can't collide across fields.
    static func commentsKey(category: String, vendor: String, workDate: String,
                            amount: String, receiptFilename: String) -> String {
        [category, vendor, workDate, amount, receiptFilename].joined(separator: "\u{1F}")
    }

    /// Moves a receipt file from one category's folder to another (in
    /// Documents) — used when an edit changes the category but not the photo.
    static func moveFile(filename: String, from oldCategory: String, to newCategory: String) throws {
        guard let sourceURL = existingFileURL(category: oldCategory, filename: filename) else { return }
        guard let destFolder = documentsRootURL()?.appendingPathComponent(newCategory, isDirectory: true) else {
            throw LocalStoreError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let destURL = destFolder.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: sourceURL, to: destURL)
    }

    /// Wipes and regenerates a category's CSV log strictly from `entries`
    /// (typically `SubmissionStore.loadHistory()` filtered to that category)
    /// — guarantees the CSV exactly matches what the Receipts screen shows,
    /// fixing any drift (stray rows, deleted files that changed the location
    /// of the log, etc). `HistoryEntry` doesn't carry Comments, so rebuilt
    /// rows have that column blank; only affects entries submitted before
    /// this rebuild — new submissions still get Comments filled in normally.
    static func rebuildLog(category: String, entries: [HistoryEntry]) throws {
        guard let folder = documentsRootURL()?.appendingPathComponent(category, isDirectory: true) else {
            throw LocalStoreError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csvURL = folder.appendingPathComponent(logFileName(category: category))

        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var content = csvRow(AppConstants.sheetHeader)
        for entry in sorted {
            content += csvRow([
                entry.vendor, entry.workDate, entry.amount, "",
                entry.receiptLink, dateString(entry.timestamp),
            ])
        }

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: csvURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// The category's CSV log location in the main app's Documents directory
    /// — used to deep-link into the Files app. Returned even if the file
    /// doesn't exist yet (e.g. nothing drained there); callers should check
    /// existence before opening it.
    static func documentsLogFileURL(category: String) -> URL? {
        documentsRootURL()?
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(logFileName(category: category))
    }

    /// Builds a CSV (header + matching rows) for `entries` by filtering the
    /// category's real on-disk CSV — unlike `rebuildLog`, this preserves the
    /// Comments column, since it reads real rows rather than regenerating
    /// them from `HistoryEntry` (which never stored Comments).
    static func filteredCSV(category: String, entries: [HistoryEntry]) -> String {
        var content = csvRow(AppConstants.sheetHeader)
        guard let csvURL = existingLogURL(category: category),
              let text = try? String(contentsOf: csvURL, encoding: .utf8) else {
            // No CSV on disk (e.g. spool not drained) — fall back to
            // regenerating from HistoryEntry so the archive still has rows,
            // just without Comments for this edge case.
            for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
                content += csvRow([entry.vendor, entry.workDate, entry.amount, "", entry.receiptLink, dateString(entry.timestamp)])
            }
            return content
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }
            let matches = entries.contains {
                $0.vendor == fields[0] && $0.workDate == fields[1]
                    && $0.amount == fields[2] && $0.receiptLink == fields[4]
            }
            if matches { content += String(line) + "\n" }
        }
        return content
    }

    /// Zips a folder's contents using `NSFileCoordinator`'s `.forUploading`
    /// option — iOS creates the zip natively, no third-party library needed.
    /// The system-provided zip lives at a temporary URL that's cleaned up
    /// once the coordination block returns, so this copies it out to a
    /// caller-owned location under `name` before returning.
    static func zipFolder(at folderURL: URL, name: String) throws -> URL {
        var resultError: Error?
        var zippedTempURL: URL?
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        coordinator.coordinate(readingItemAt: folderURL, options: [.forUploading], error: &coordinatorError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
                zippedTempURL = dest
            } catch {
                resultError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let resultError { throw resultError }
        guard let zippedTempURL else { throw LocalStoreError.zipFailed }
        return zippedTempURL
    }

    /// Copies a single file from a restore's extracted-zip temp folder into
    /// this category's Documents folder, preserving its filename. No-ops if
    /// a file with that name already exists — restore is purely additive,
    /// it never overwrites anything already on this phone. Returns whether a
    /// copy actually happened, so callers can tell "brought a missing file
    /// back" apart from "already had it."
    @discardableResult
    static func importFile(from sourceURL: URL, category: String, filename: String) throws -> Bool {
        guard let destFolder = documentsRootURL()?.appendingPathComponent(category, isDirectory: true) else {
            throw LocalStoreError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let destURL = destFolder.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destURL.path) else { return false }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return true
    }

    /// Appends rows from a restored backup's CSV that aren't already present
    /// (matched the same way `removeRow` matches: vendor/workDate/amount/
    /// receiptFilename), preserving Comments from the backup. Writes the
    /// backup's CSV wholesale if this category has no local CSV yet.
    static func mergeCSVRows(category: String, csvText: String) throws {
        let backupLines = csvText.split(separator: "\n", omittingEmptySubsequences: true)
        guard backupLines.count > 1 else { return } // header only, nothing to merge

        guard let existingURL = existingLogURL(category: category) else {
            guard let destFolder = documentsRootURL()?.appendingPathComponent(category, isDirectory: true) else {
                throw LocalStoreError.appGroupUnavailable
            }
            try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
            try csvText.write(to: destFolder.appendingPathComponent(logFileName(category: category)), atomically: true, encoding: .utf8)
            return
        }

        let existingText = (try? String(contentsOf: existingURL, encoding: .utf8)) ?? csvRow(AppConstants.sheetHeader)
        let existingKeys = Set(existingText.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map { line -> String in
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { return String(line) }
            return "\(fields[0])|\(fields[1])|\(fields[2])|\(fields[4])"
        })

        var toAppend = ""
        for line in backupLines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }
            let key = "\(fields[0])|\(fields[1])|\(fields[2])|\(fields[4])"
            if !existingKeys.contains(key) { toAppend += String(line) + "\n" }
        }
        guard !toAppend.isEmpty else { return }

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: existingURL, options: .forMerging, error: &coordinatorError) { url in
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = toAppend.data(using: .utf8) { handle.write(data) }
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// The category's own folder in the main app's Documents directory —
    /// where every receipt file (primary and extras) for that category
    /// actually lives, visible in the Files app.
    static func documentsCategoryFolderURL(category: String) -> URL? {
        documentsRootURL()?.appendingPathComponent(category, isDirectory: true)
    }

    // MARK: - Backup library

    /// Where full-backup zips are kept on-device, visible in Files under
    /// On My iPhone > Receipt Drop > Backups — lets Restore list them by
    /// date instead of requiring the document picker every time (which only
    /// exists because the app has no way to see back into wherever a share
    /// sheet destination like iCloud Drive actually put the file).
    static func backupsFolderURL() -> URL? {
        guard let folder = documentsRootURL()?.deletingLastPathComponent().appendingPathComponent(backupsDirName, isDirectory: true) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// All backup zips on-device, newest first (by modification date — the
    /// filename only has day granularity, so two same-day backups need mtime
    /// to sort correctly).
    static func listBackups() -> [URL] {
        guard let folder = backupsFolderURL(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d0 > d1
            }
    }

    /// Deletes all but the newest `keeping` backups — each retained backup
    /// costs roughly the full size of your photos, so unbounded retention
    /// isn't free the way it is for CSVs/history.
    static func pruneBackups(keeping: Int = 3) {
        let backups = listBackups()
        guard backups.count > keeping else { return }
        for url in backups[keeping...] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Finds the category's CSV log, checking Documents (drained) then the
    /// App Group spool (not yet drained).
    private static func existingLogURL(category: String) -> URL? {
        let name = logFileName(category: category)
        if let docURL = documentsRootURL()?.appendingPathComponent(category, isDirectory: true).appendingPathComponent(name),
           FileManager.default.fileExists(atPath: docURL.path) {
            return docURL
        }
        if let spoolURL = spoolRootURL()?.appendingPathComponent(category, isDirectory: true).appendingPathComponent(name),
           FileManager.default.fileExists(atPath: spoolURL.path) {
            return spoolURL
        }
        return nil
    }

    /// Minimal RFC 4180 line parser — handles quoted fields containing commas,
    /// quotes, or newlines (the fields `csvRow`/`csvField` can produce).
    private static func parseCSVLine(_ line: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if inQuotes {
                if char == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    /// Includes a short random suffix — the timestamp alone is only
    /// second-granular, so saving multiple files in quick succession (e.g.
    /// several extra attachments added in one Edit save) previously produced
    /// identical names and silently overwrote each other.
    static func fileName(category: String, kind: ReceiptKind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        let suffix = String(format: "%04x", UInt16.random(in: 0...0xFFFF))
        return "\(category)_\(stamp)_\(suffix).\(kind.fileExtension)"
    }

    private static func logFileName(category: String) -> String {
        "\(category)_log.csv"
    }

    static func todayString() -> String { dateString(Date()) }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        return formatter.string(from: date)
    }

    // MARK: - CSV

    /// RFC 4180 escaping: quote any field containing a comma, quote, or newline.
    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

enum LocalStoreError: LocalizedError {
    case appGroupUnavailable
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "Couldn't access shared app storage."
        case .zipFailed: return "Couldn't create the zip archive."
        }
    }
}

private extension URL {
    var hasDirectoryPath: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

enum ZipReaderError: LocalizedError {
    case invalidZip
    case unsupportedEntry(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidZip: return "This doesn't look like a valid backup zip file."
        case .unsupportedEntry(let name): return "Unsupported entry in zip: \(name)"
        case .unsafePath(let name): return "Unsafe path in zip: \(name)"
        }
    }
}

/// Minimal zip reader for zips this app itself produced (via
/// `LocalReceiptStore.zipFolder`), used by Restore — not a general-purpose
/// zip library. Only "stored" and "deflate" entries are supported (the only
/// methods iOS's own zip creation uses); anything else is rejected rather
/// than mis-handled. Paths are sanitized against zip-slip even though the
/// input is expected to be trusted, since it's cheap insurance.
///
/// Uses the `Compression` framework's `COMPRESSION_ZLIB` algorithm, which —
/// despite the name — implements raw DEFLATE (RFC 1951) with no zlib/gzip
/// wrapper, exactly matching zip's method-8 compression.
enum MinimalZipReader {
    private struct CentralDirectoryEntry {
        let filename: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    /// Lists entry paths without extracting/decompressing anything — just
    /// the central directory, which is cheap even for a large zip full of
    /// photos. Used to sanity-check a picked file (e.g. "is this actually a
    /// full backup, not an Archive export?") before committing to a full
    /// restore.
    static func listEntryNames(zipURL: URL) throws -> [String] {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        return try centralDirectoryEntries(in: data).map(\.filename)
    }

    static func extract(zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let entries = try centralDirectoryEntries(in: data)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            let sanitized = try sanitize(entry.filename)
            let destURL = destination.appendingPathComponent(sanitized)
            if entry.filename.hasSuffix("/") {
                try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fileData = try extractFileData(from: data, entry: entry)
            try fileData.write(to: destURL)
        }
    }

    private static func sanitize(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else { throw ZipReaderError.unsafePath(path) }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") else { throw ZipReaderError.unsafePath(path) }
        return components.joined(separator: "/")
    }

    private static func centralDirectoryEntries(in data: Data) throws -> [CentralDirectoryEntry] {
        let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard let eocdStart = findLast(sequence: eocdSignature, in: data) else {
            throw ZipReaderError.invalidZip
        }
        let eocd = data[eocdStart...]
        guard eocd.count >= 22 else { throw ZipReaderError.invalidZip }

        let totalEntries = readUInt16(eocd, offset: 10)
        let cdSize = readUInt32(eocd, offset: 12)
        let cdOffset = readUInt32(eocd, offset: 16)
        guard Int(cdOffset) + Int(cdSize) <= data.count else { throw ZipReaderError.invalidZip }

        let cdSignature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        var entries: [CentralDirectoryEntry] = []
        var pos = Int(cdOffset) + data.startIndex

        for _ in 0..<totalEntries {
            guard pos + 46 <= data.endIndex else { break }
            let header = data[pos...]
            guard Array(header.prefix(4)) == cdSignature else { throw ZipReaderError.invalidZip }

            let method = readUInt16(header, offset: 10)
            let compSize = readUInt32(header, offset: 20)
            let uncompSize = readUInt32(header, offset: 24)
            let nameLen = Int(readUInt16(header, offset: 28))
            let extraLen = Int(readUInt16(header, offset: 30))
            let commentLen = Int(readUInt16(header, offset: 32))
            let localOffset = readUInt32(header, offset: 42)

            let nameStart = pos + 46
            guard nameStart + nameLen <= data.endIndex else { throw ZipReaderError.invalidZip }
            let filename = String(data: data[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? ""

            entries.append(CentralDirectoryEntry(
                filename: filename, compressionMethod: method,
                compressedSize: compSize, uncompressedSize: uncompSize,
                localHeaderOffset: localOffset))
            pos = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extractFileData(from data: Data, entry: CentralDirectoryEntry) throws -> Data {
        let localSignature: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
        let pos = Int(entry.localHeaderOffset) + data.startIndex
        guard pos + 30 <= data.endIndex else { throw ZipReaderError.invalidZip }
        let header = data[pos...]
        guard Array(header.prefix(4)) == localSignature else { throw ZipReaderError.invalidZip }

        let nameLen = Int(readUInt16(header, offset: 26))
        let extraLen = Int(readUInt16(header, offset: 28))
        let dataStart = pos + 30 + nameLen + extraLen
        guard dataStart + Int(entry.compressedSize) <= data.endIndex else { throw ZipReaderError.invalidZip }
        let compressed = Data(data[dataStart..<(dataStart + Int(entry.compressedSize))])

        switch entry.compressionMethod {
        case 0: return compressed
        case 8: return try inflate(compressed, uncompressedSize: Int(entry.uncompressedSize))
        default: throw ZipReaderError.unsupportedEntry(entry.filename)
        }
    }

    private static func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let resultSize = output.withUnsafeMutableBytes { destBuffer -> Int in
            compressed.withUnsafeBytes { srcBuffer -> Int in
                guard let destPtr = destBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destPtr, uncompressedSize, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard resultSize == uncompressedSize else { throw ZipReaderError.invalidZip }
        return output
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) | (UInt32(data[start + 1]) << 8)
            | (UInt32(data[start + 2]) << 16) | (UInt32(data[start + 3]) << 24)
    }

    /// Scans backward for the End-of-Central-Directory signature — it sits
    /// after a variable-length comment field, so it can't be found by a
    /// fixed offset from the end of the file.
    private static func findLast(sequence: [UInt8], in data: Data) -> Int? {
        guard data.count >= sequence.count else { return nil }
        let bytes = [UInt8](data)
        var i = bytes.count - sequence.count
        while i >= 0 {
            if Array(bytes[i..<(i + sequence.count)]) == sequence {
                return i + data.startIndex
            }
            i -= 1
        }
        return nil
    }
}
