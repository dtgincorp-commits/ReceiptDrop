import Foundation

/// The kind of receipt file we handle. Kept in Shared (not the extension's
/// SharedAttachment) so the submission pipeline, Drive upload, and Claude
/// extraction — all in Shared — can reason about the file without importing
/// UIKit or the extension's view types.
enum ReceiptKind: String, Codable {
    case image
    case pdf

    /// File extension used when naming the uploaded Drive file / queued file.
    var fileExtension: String { self == .image ? "jpg" : "pdf" }

    /// MIME type sent to Drive and as the Claude content-block media_type.
    /// Image attachments are always re-encoded to JPEG before submission,
    /// so this is safe to hard-code.
    var mimeType: String { self == .image ? "image/jpeg" : "application/pdf" }
}

/// Structured data Claude reads off a receipt. All fields are strings so they
/// round-trip cleanly into a spreadsheet row.
struct ExtractedReceipt {
    let vendor: String
    let workDate: String   // normalized to yyyy-MM-dd
    let amount: String     // plain number, no currency symbol
    let comments: String
    /// True if the extraction backend reported low confidence, or a heuristic
    /// safety net (empty vendor/amount, unparseable date) caught a likely-bad
    /// read. Model-agnostic by design: whatever fills these in — Claude today,
    /// an on-device model later — the HITL flow downstream is the same.
    let needsReview: Bool
    let reviewReason: String

    /// Heuristic safety net shared by every `ReceiptExtractor` — independent
    /// of whatever confidence the model itself reports, catches empty
    /// vendor/amount, an unparseable date (which `ClaudeService.normalizeDate`
    /// silently defaults to today), or an implausible-but-well-formed date.
    /// Keeping this in one place means Claude, OpenAI, and Gemini all get
    /// identical HITL flagging behavior.
    static func build(vendor: String, rawWorkDate: String, amount: String, comments: String,
                      modelReportedLowConfidence: Bool, modelReason: String) -> ExtractedReceipt {
        var needsReview = modelReportedLowConfidence
        var reason = modelReason
        if vendor.isEmpty {
            needsReview = true
            if reason.isEmpty { reason = "Vendor name missing" }
        }
        if amount.isEmpty || Double(amount) == nil || Double(amount) == 0 {
            needsReview = true
            if reason.isEmpty { reason = "Amount missing or unreadable" }
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = AppConstants.sheetDateFormat
        if rawWorkDate.isEmpty || dateFormatter.date(from: rawWorkDate) == nil {
            needsReview = true
            if reason.isEmpty { reason = "Date unreadable, defaulted to today" }
        } else if let parsed = dateFormatter.date(from: rawWorkDate) {
            // Well-formed but implausible: a model working from noisy OCR
            // text (no visual layout to anchor on) can hallucinate a
            // plausible-looking date rather than admitting none was found —
            // this catches that even though it passes the parse check above.
            let calendar = Calendar.current
            if parsed > calendar.date(byAdding: .day, value: 1, to: Date())! {
                needsReview = true
                if reason.isEmpty { reason = "Date is in the future" }
            } else if parsed < calendar.date(byAdding: .month, value: -15, to: Date())! {
                needsReview = true
                if reason.isEmpty { reason = "Date is over a year old — please confirm" }
            }
        }
        return ExtractedReceipt(
            vendor: vendor,
            workDate: ClaudeService.normalizeDate(rawWorkDate),
            amount: amount,
            comments: comments,
            needsReview: needsReview,
            reviewReason: reason)
    }
}

/// Shared prompt preamble every `ReceiptExtractor` prepends to its request —
/// keeping this in one place means Claude/OpenAI/Gemini give the model
/// identical grounding. Two things an LLM has no way to know on its own:
/// today's date (so it can judge "is this date plausible?" instead of
/// guessing blind) and what this category is actually for (so it can write
/// better Comments and sanity-check whether the receipt looks like it
/// belongs), if the user bothered to write one.
enum ExtractionPrompt {
    static func preamble(categoryContext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        var lines = ["Today's date is \(formatter.string(from: Date())). Receipts are usually recent — if you can't find a clear date on the receipt, return an empty string; never guess or invent one."]
        if !categoryContext.isEmpty {
            lines.append("This receipt is being filed under a category described by the user as: \"\(categoryContext)\". Use this to write more specific Comments, and lower your confidence if the receipt looks unrelated to this description.")
        }
        return lines.joined(separator: " ")
    }
}

/// A backend that can turn a receipt (image/PDF bytes, or text already OCR'd
/// on-device) into structured fields. `ClaudeService` was the first and only
/// implementation; `OpenAIService`/`GeminiService` conform the same way, and
/// a future on-device Apple Intelligence backend would too — nothing
/// downstream (HITL flagging, HistoryEntry, the pipeline) needs to change
/// when the engine changes, since they all speak `ExtractedReceipt`.
protocol ReceiptExtractor {
    /// `categoryContext` is the user-written description of the category
    /// this receipt is being filed under (e.g. "Expenses for my IT company",
    /// "Rental property — Monteras St"), if one was set — gives the model
    /// real signal for writing better Comments and judging whether a receipt
    /// looks like it belongs. Empty string if the category has no description.
    func extract(data: Data, kind: ReceiptKind, categoryContext: String) async throws -> ExtractedReceipt
    func extract(ocrText: String, categoryContext: String) async throws -> ExtractedReceipt
}

/// Which AI backend performs extraction. Stored in App Group UserDefaults so
/// the share extension honors the same choice as the main app.
enum ExtractionProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case openAI
    case gemini
    case appleOnDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .appleOnDevice: return "Apple On-Device"
        }
    }

    /// Apple On-Device requires iOS 26 + the Foundation Models framework —
    /// not available on this toolchain yet. Listed so the option is visible
    /// (and the future path obvious) without being selectable.
    var isAvailable: Bool { self != .appleOnDevice }
}

/// Whether extraction sends the full image/PDF, or on-device OCR text only
/// (cheaper/faster, with an automatic full-image retry if the result looks
/// unreliable — see `SubmissionPipeline`).
enum ExtractionMode: String, Codable, CaseIterable, Identifiable {
    case fullImage
    case onDeviceOCR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullImage: return "Full Image"
        case .onDeviceOCR: return "On-Device OCR Text"
        }
    }
}

/// Reads/writes the extraction provider + mode from App Group UserDefaults
/// (not `@AppStorage`, which defaults to `UserDefaults.standard` — the share
/// extension runs in a different sandbox and wouldn't see the same value).
enum ExtractionSettings {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    static var provider: ExtractionProvider {
        get {
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.extractionProvider),
                  let value = ExtractionProvider(rawValue: raw) else { return .claude }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.extractionProvider) }
    }

    static var mode: ExtractionMode {
        get {
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.extractionMode),
                  let value = ExtractionMode(rawValue: raw) else { return .fullImage }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.extractionMode) }
    }

    /// The extractor instance for the currently selected provider. Apple
    /// On-Device isn't implemented yet (`isAvailable == false`), so it's
    /// unreachable here — the Settings picker prevents selecting it.
    static func currentExtractor() -> ReceiptExtractor {
        switch provider {
        case .claude: return ClaudeService()
        case .openAI: return OpenAIService()
        case .gemini: return GeminiService()
        case .appleOnDevice: return ClaudeService() // unreachable; picker disables this option
        }
    }
}

// MARK: - Archive & Backup

enum BackupReminderFrequency: String, Codable, CaseIterable, Identifiable {
    case off, weekly, monthly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
    var intervalDays: Int? {
        switch self {
        case .off: return nil
        case .weekly: return 7
        case .monthly: return 30
        }
    }
}

/// Backup stamp + reminder preference, in App Group defaults.
enum BackupSettings {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    static var lastBackupDate: Date? {
        get { defaults.object(forKey: AppConstants.DefaultsKeys.lastBackupDate) as? Date }
        set { defaults.set(newValue, forKey: AppConstants.DefaultsKeys.lastBackupDate) }
    }

    static var reminderFrequency: BackupReminderFrequency {
        get {
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.backupReminderFrequency),
                  let value = BackupReminderFrequency(rawValue: raw) else { return .off }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: AppConstants.DefaultsKeys.backupReminderFrequency) }
    }

    /// True if a reminder is due: frequency isn't Off, at least one backup
    /// has ever been made (no nagging a user who's never backed up once —
    /// that's a decision to surface once, on the Archive & Backup screen
    /// itself, not a repeated interruption), and enough days have passed.
    static func isReminderDue() -> Bool {
        guard let days = reminderFrequency.intervalDays, let lastBackupDate else { return false }
        return Date().timeIntervalSince(lastBackupDate) >= Double(days) * 86400
    }
}

enum ArchiveBackupError: LocalizedError {
    case noReceipts

    var errorDescription: String? {
        "No receipts found for that period."
    }
}

/// Builds Archive (period-scoped) and Backup (everything) zip exports.
/// "Period" is defined by each receipt's work date, falling back to its scan
/// date when the work date is missing/unparseable — mirroring the Receipts
/// screen's own grouping logic, so an archive matches what you'd see there.
enum ArchiveBackupService {
    static func periodDate(for entry: HistoryEntry) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        if !entry.workDate.isEmpty, let parsed = formatter.date(from: entry.workDate) {
            return parsed
        }
        return entry.timestamp
    }

    static func availableYears() -> [Int] {
        let years = SubmissionStore.loadHistory().map { Calendar.current.component(.year, from: periodDate(for: $0)) }
        return Array(Set(years)).sorted(by: >)
    }

    static func availableMonths(inYear year: Int) -> [Int] {
        let months = entries(inYear: year).map { Calendar.current.component(.month, from: periodDate(for: $0)) }
        return Array(Set(months)).sorted()
    }

    static func entries(inYear year: Int) -> [HistoryEntry] {
        SubmissionStore.loadHistory().filter { Calendar.current.component(.year, from: periodDate(for: $0)) == year }
    }

    static func entries(inYear year: Int, month: Int) -> [HistoryEntry] {
        SubmissionStore.loadHistory().filter {
            let date = periodDate(for: $0)
            let calendar = Calendar.current
            return calendar.component(.year, from: date) == year && calendar.component(.month, from: date) == month
        }
    }

    static func entries(from start: Date, to end: Date) -> [HistoryEntry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: start)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return SubmissionStore.loadHistory().filter {
            let date = periodDate(for: $0)
            return date >= startOfDay && date < endOfDay
        }
    }

    /// Builds a period archive: per-category folders (hard-linked photos +
    /// extras, never copies — zero extra disk space) plus a CSV filtered
    /// from the real on-disk logs so Comments survive. `includeEverything`
    /// (used by `buildFullBackup`) also writes manifest.json + history.json
    /// at the zip root — never Keychain/API keys, which must never leave
    /// the device in a file that could be AirDropped or emailed.
    static func buildArchive(label: String, entries: [HistoryEntry], includeEverything: Bool = false) throws -> URL {
        guard !entries.isEmpty else { throw ArchiveBackupError.noReceipts }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptDropArchive_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let byCategory = Dictionary(grouping: entries, by: { $0.category })
        for (category, categoryEntries) in byCategory {
            let categoryFolder = tempRoot.appendingPathComponent(category, isDirectory: true)
            try FileManager.default.createDirectory(at: categoryFolder, withIntermediateDirectories: true)

            for entry in categoryEntries {
                for filename in [entry.receiptLink] + entry.extraFiles {
                    guard !filename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(filename),
                          let source = LocalReceiptStore.existingFileURL(category: category, filename: filename) else { continue }
                    let dest = categoryFolder.appendingPathComponent(filename)
                    guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
                    // Hard link (zero extra bytes on APFS); fall back to a
                    // copy if linking fails for any reason.
                    if (try? FileManager.default.linkItem(at: source, to: dest)) == nil {
                        try? FileManager.default.copyItem(at: source, to: dest)
                    }
                }
            }

            let csvContent = LocalReceiptStore.filteredCSV(category: category, entries: categoryEntries)
            try csvContent.write(to: categoryFolder.appendingPathComponent("\(category)_log.csv"), atomically: true, encoding: .utf8)
        }

        if includeEverything {
            let manifest: [String: Any] = [
                "categories": CategoryStore.shared.categories,
                "categoryDescriptions": CategoryStore.shared.descriptions,
                "extractionProvider": ExtractionSettings.provider.rawValue,
                "extractionMode": ExtractionSettings.mode.rawValue,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "backupDate": ISO8601DateFormatter().string(from: Date()),
            ]
            if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try manifestData.write(to: tempRoot.appendingPathComponent("manifest.json"))
            }
            let historyEncoder = JSONEncoder()
            historyEncoder.dateEncodingStrategy = .iso8601
            historyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let historyData = try? historyEncoder.encode(SubmissionStore.loadHistory()) {
                try historyData.write(to: tempRoot.appendingPathComponent("history.json"))
            }
        }

        return try LocalReceiptStore.zipFolder(at: tempRoot, name: label)
    }

    /// Everything: all receipts, drained first so nothing the share
    /// extension wrote since the app was last opened gets missed.
    static func buildFullBackup() throws -> URL {
        LocalReceiptStore.drainSpoolIntoDocuments()
        let label = "ReceiptDrop_Backup_\(LocalReceiptStore.todayString())"
        return try buildArchive(label: label, entries: SubmissionStore.loadHistory(), includeEverything: true)
    }
}

enum RestoreError: LocalizedError {
    case notAFullBackup

    var errorDescription: String? {
        "This is an Archive export, not a full backup — Restore needs a zip made with \"Back Up Now\"."
    }
}

struct RestoreSummary {
    var receiptsRestored = 0
    var receiptsSkipped = 0
}

/// Restores a full backup zip (from `ArchiveBackupService.buildFullBackup`).
/// Strictly additive: never overwrites or deletes anything already on this
/// phone — only adds what's missing, matched by `HistoryEntry.id`. Safe to
/// run on the same zip twice (second run reports everything as skipped) and
/// safe to run into a phone that already has receipts (a merge, not a wipe).
enum RestoreService {
    static func restore(zipURL: URL) throws -> RestoreSummary {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptDropRestore_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try MinimalZipReader.extract(zipURL: zipURL, to: tempRoot)

        let historyURL = tempRoot.appendingPathComponent("history.json")
        let manifestURL = tempRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: historyURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RestoreError.notAFullBackup
        }

        restoreManifest(at: manifestURL, isFreshInstall: SubmissionStore.loadHistory().isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backupEntries = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: historyURL))

        let existingIDs = Set(SubmissionStore.loadHistory().map { $0.id })
        let newEntries = backupEntries.filter { !existingIDs.contains($0.id) }

        for entry in newEntries {
            for filename in [entry.receiptLink] + entry.extraFiles {
                guard !filename.isEmpty, !SubmissionPipeline.isPlaceholderLabel(filename) else { continue }
                let sourceURL = tempRoot.appendingPathComponent(entry.category).appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                try? LocalReceiptStore.importFile(from: sourceURL, category: entry.category, filename: filename)
            }
        }

        for category in Set(backupEntries.map(\.category)) {
            let backupCSVURL = tempRoot.appendingPathComponent(category).appendingPathComponent("\(category)_log.csv")
            if let backupCSVText = try? String(contentsOf: backupCSVURL, encoding: .utf8) {
                try? LocalReceiptStore.mergeCSVRows(category: category, csvText: backupCSVText)
            }
        }

        let restoredCount = SubmissionStore.mergeHistory(backupEntries)
        return RestoreSummary(receiptsRestored: restoredCount, receiptsSkipped: backupEntries.count - restoredCount)
    }

    /// Categories/descriptions merge in regardless (additive, never clobbers
    /// an existing description). Extraction provider/mode are only applied
    /// on a fresh install — restoring into an already-configured phone
    /// should never silently change live settings.
    private static func restoreManifest(at url: URL, isFreshInstall: Bool) {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let categories = manifest["categories"] as? [String] {
            for category in categories { CategoryStore.shared.add(category) }
        }
        if let descriptions = manifest["categoryDescriptions"] as? [String: String] {
            for (category, description) in descriptions
            where CategoryStore.shared.description(for: category).isEmpty {
                CategoryStore.shared.setDescription(description, for: category)
            }
        }
        guard isFreshInstall else { return }
        if let providerRaw = manifest["extractionProvider"] as? String,
           let provider = ExtractionProvider(rawValue: providerRaw), provider.isAvailable {
            ExtractionSettings.provider = provider
        }
        if let modeRaw = manifest["extractionMode"] as? String,
           let mode = ExtractionMode(rawValue: modeRaw) {
            ExtractionSettings.mode = mode
        }
    }
}

/// Human-in-the-loop status of a saved receipt, surfaced in the Receipts list.
enum VerificationStatus: String, Codable {
    case none         // no review needed, never flagged
    case needsReview  // low confidence or heuristic trigger — unreviewed
    case verified     // a human has saved this entry via Edit
}

/// A successful submission, appended to the App Group history (newest first).
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let category: String
    let vendor: String
    let workDate: String
    let amount: String
    let receiptLink: String
    let timestamp: Date
    var verificationStatus: VerificationStatus = .none
    var reviewReason: String = ""
    /// Extra photos/PDFs attached after the fact (e.g. a second page or a
    /// warranty slip), beyond the primary `receiptLink`. Purely supplemental —
    /// never sent to Claude, never written to the CSV. Filenames live in the
    /// same category folder as the primary file.
    var extraFiles: [String] = []

    init(id: UUID = UUID(), category: String, vendor: String, workDate: String, amount: String,
         receiptLink: String, timestamp: Date,
         verificationStatus: VerificationStatus = .none, reviewReason: String = "",
         extraFiles: [String] = []) {
        self.id = id
        self.category = category
        self.vendor = vendor
        self.workDate = workDate
        self.amount = amount
        self.receiptLink = receiptLink
        self.timestamp = timestamp
        self.verificationStatus = verificationStatus
        self.reviewReason = reviewReason
        self.extraFiles = extraFiles
    }

    // Custom Decodable so history persisted before these fields existed
    // (App Group UserDefaults) still decodes, defaulting to `.none`/empty.
    private enum CodingKeys: String, CodingKey {
        case id, category, vendor, workDate, amount, receiptLink, timestamp
        case verificationStatus, reviewReason, extraFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try container.decode(String.self, forKey: .category)
        vendor = try container.decode(String.self, forKey: .vendor)
        workDate = try container.decode(String.self, forKey: .workDate)
        amount = try container.decode(String.self, forKey: .amount)
        receiptLink = try container.decode(String.self, forKey: .receiptLink)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        verificationStatus = try container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .none
        reviewReason = try container.decodeIfPresent(String.self, forKey: .reviewReason) ?? ""
        extraFiles = try container.decodeIfPresent([String].self, forKey: .extraFiles) ?? []
    }
}

/// A failed submission whose bytes are parked in the App Group container for
/// a later retry from the main app.
struct QueueEntry: Codable, Identifiable {
    var id = UUID()
    let category: String
    let filename: String   // file under <container>/PendingReceipts
    let kind: ReceiptKind
    let error: String
    let timestamp: Date
}
