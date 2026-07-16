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

    /// Saves `data` into the App Group spool for `category`, returning the
    /// filename used (also the name the file will keep once drained).
    static func save(data: Data, category: String, kind: ReceiptKind) throws -> String {
        let folder = try spoolCategoryFolder(category)
        let name = fileName(category: category, kind: kind)
        try data.write(to: folder.appendingPathComponent(name))
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
                            amount: String, receiptFilename: String) throws {
        try removeRow(category: category, vendor: vendor, workDate: workDate,
                      amount: amount, receiptFilename: receiptFilename)

        if !receiptFilename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(receiptFilename),
           let fileURL = existingFileURL(category: category, filename: receiptFilename) {
            try? FileManager.default.removeItem(at: fileURL)
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

    /// The category's CSV log location in the main app's Documents directory
    /// — used to deep-link into the Files app. Returned even if the file
    /// doesn't exist yet (e.g. nothing drained there); callers should check
    /// existence before opening it.
    static func documentsLogFileURL(category: String) -> URL? {
        documentsRootURL()?
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(logFileName(category: category))
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

    static func fileName(category: String, kind: ReceiptKind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        return "\(category)_\(stamp).\(kind.fileExtension)"
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

    var errorDescription: String? {
        "Couldn't access shared app storage."
    }
}

private extension URL {
    var hasDirectoryPath: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
