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

/// The fixed business-type vocabulary used for vendor classification, shared
/// by every call site that needs it: receipt extraction (classify once at
/// save time), the search query parser (map a phrase like "restaurants" onto
/// the same token), and the one-time backfill for pre-existing receipts.
/// Deliberately a single source of truth — schema `enum` arrays for all
/// three AI providers, in both extraction and search, are built from
/// `VendorType.allCases` rather than retyped as prose in six separate
/// prompts, so the vocabulary can't silently drift between call sites.
///
/// Near-synonym categories are deliberately merged into one bucket (e.g.
/// hardware store and home improvement store share one case) — if the
/// vocabulary offered both, a vendor like Home Depot could be filed under
/// either one, and a search for one term would silently miss receipts
/// classified under the other. One bucket per real-world concept avoids that.
enum VendorType: String, CaseIterable, Codable {
    case restaurant
    case gasStation = "gas_station"
    case grocery
    case hardwareHomeImprovement = "hardware_home_improvement"
    case retail
    case autoRepair = "auto_repair"
    case lodging
    case medical
    case professionalServices = "professional_services"
    case entertainment
    case utilities
    case other

    var displayName: String {
        switch self {
        case .restaurant: return "Restaurant"
        case .gasStation: return "Gas Station"
        case .grocery: return "Grocery"
        case .hardwareHomeImprovement: return "Hardware / Home Improvement"
        case .retail: return "Retail"
        case .autoRepair: return "Auto Repair"
        case .lodging: return "Lodging"
        case .medical: return "Medical"
        case .professionalServices: return "Professional Services"
        case .entertainment: return "Entertainment"
        case .utilities: return "Utilities"
        case .other: return "Other"
        }
    }

    static var allRawValues: [String] { allCases.map(\.rawValue) }

    /// nil for anything not exactly matching a known token — callers should
    /// treat that as "unrecognized," not silently coerce to `.other`.
    static func from(_ raw: String?) -> VendorType? {
        guard let raw else { return nil }
        return VendorType(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// User-added vendor types beyond the fixed built-in vocabulary (e.g. "Tiki
/// Bar") — deliberately human-curated, not AI-invented: the user types it
/// once via Edit Receipt's "Add Custom Type…", it's saved here, and every
/// future receipt (and search) can reuse that exact same token. This is the
/// same reasoning that makes user-added Categories safe (CategoryStore) —
/// a small, deliberately-grown list stays consistent, whereas letting the
/// model freely invent new labels per receipt was the exact problem the
/// fixed VendorType vocabulary was built to avoid.
enum CustomVendorTypeStore {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private static let key = "customVendorTypes"

    static var customTypes: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Adds a new custom type if it's non-empty and doesn't collide
    /// (case-insensitively) with a built-in type or an existing custom one.
    /// Returns the canonical stored string to select immediately — either
    /// the newly-added one, or the existing match if it already existed.
    @discardableResult
    static func add(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if VendorType.allRawValues.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return nil
        }
        if let existing = customTypes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        var updated = customTypes
        updated.append(trimmed)
        customTypes = updated
        return trimmed
    }

    /// Removes a custom type from the pickable list. Any receipt already
    /// tagged with it keeps that string as-is (same behavior as deleting a
    /// Category) — it just stops being offered for future receipts.
    static func remove(at offsets: IndexSet) {
        var updated = customTypes
        updated.remove(atOffsets: offsets)
        customTypes = updated
    }
}

/// Resolves a vendor-type token against *everything* currently valid — the
/// fixed `VendorType` vocabulary plus whatever custom types the user has
/// added — used everywhere a model's output (extraction, search-query
/// parsing, backfill classification) needs validating against the full set,
/// not just the built-in enum. Kept separate from `VendorType` itself since
/// custom types have no corresponding enum case (Swift enums are static).
enum VendorTypeToken {
    /// Every string an AI schema `enum` should currently allow.
    static var allValidValues: [String] { VendorType.allRawValues + CustomVendorTypeStore.customTypes }

    /// The canonical stored form of `raw` if it matches a built-in or custom
    /// type (case-insensitive), or nil if it matches neither.
    static func resolve(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let builtin = VendorType(rawValue: trimmed.lowercased()) { return builtin.rawValue }
        return CustomVendorTypeStore.customTypes.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Display label for any valid vendor-type token, built-in or custom.
    static func displayName(for raw: String) -> String {
        if let builtin = VendorType(rawValue: raw) { return builtin.displayName }
        return raw
    }
}

/// Structured data Claude reads off a receipt. All fields are strings so they
/// round-trip cleanly into a spreadsheet row.
struct ExtractedReceipt {
    let vendor: String
    let workDate: String   // normalized to yyyy-MM-dd
    let amount: String     // plain number, no currency symbol
    let comments: String
    /// A `VendorType` raw value, or empty string if the model couldn't
    /// confidently place it (treated the same as "unclassified" —
    /// searchable later via the backfill action, never blocks saving).
    let vendorType: String
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
                      rawVendorType: String, modelReportedLowConfidence: Bool, modelReason: String) -> ExtractedReceipt {
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
        // Only ever store a recognized token (built-in or custom) or empty —
        // never let a model's free-text deviation into the vocabulary
        // silently corrupt it.
        let resolvedVendorType = VendorTypeToken.resolve(rawVendorType) ?? ""
        return ExtractedReceipt(
            vendor: vendor,
            workDate: ClaudeService.normalizeDate(rawWorkDate),
            amount: amount,
            comments: comments,
            vendorType: resolvedVendorType,
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

    /// Apple On-Device requires iOS 26 + the Foundation Models framework.
    /// Selectable on iOS 26+; whether the model is actually ready on this
    /// specific device (eligible hardware + Apple Intelligence enabled) is
    /// checked at extraction time, surfacing a clear error if not.
    var isAvailable: Bool {
        guard self == .appleOnDevice else { return true }
        if #available(iOS 26.0, *) { return true }
        return false
    }
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

/// Raised when Offline mode is on but a network-dependent provider is chosen.
enum OfflineModeError: LocalizedError {
    case cloudProviderBlocked(ExtractionProvider)

    var errorDescription: String? {
        switch self {
        case .cloudProviderBlocked(let provider):
            return "Offline mode is on, so \(provider.displayName) (which needs the internet) is blocked. Switch the AI Provider to Apple On-Device in Settings, or turn off Offline mode."
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
            // Gemini is the default: it has a genuine free tier (no card,
            // no per-user cost), unlike Claude/OpenAI which always bill.
            guard let raw = defaults.string(forKey: AppConstants.DefaultsKeys.extractionProvider),
                  let value = ExtractionProvider(rawValue: raw) else { return .gemini }
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

    /// When true, the app refuses the cloud providers (Claude/OpenAI/Gemini)
    /// and works only with Apple's on-device model — nothing leaves the phone.
    /// Stored in the App Group so the share extension honors it too.
    static var offlineOnly: Bool {
        get { defaults.bool(forKey: AppConstants.DefaultsKeys.offlineOnly) }
        set { defaults.set(newValue, forKey: AppConstants.DefaultsKeys.offlineOnly) }
    }

    /// Throws if Offline mode is on but a cloud provider is selected. Call at
    /// the start of any extraction or search so the block is enforced
    /// everywhere (main app *and* share extension), not just hidden in the UI.
    static func assertProviderAllowed() throws {
        if offlineOnly && provider != .appleOnDevice {
            throw OfflineModeError.cloudProviderBlocked(provider)
        }
    }

    /// The extractor instance for the currently selected provider.
    static func currentExtractor() -> ReceiptExtractor {
        switch provider {
        case .claude: return ClaudeService()
        case .openAI: return OpenAIService()
        case .gemini: return GeminiService()
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return FoundationModelsService() }
            #endif
            return GeminiService() // fallback on older OS / toolchains
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

        // The label-named folder goes *inside* a throwaway UUID parent:
        // `.forUploading` zips include the zipped folder itself as the zip's
        // top-level entry, so this is the name users see when they unzip the
        // backup in the Files app (and the folder Restore expects to find).
        let tempParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptDropArchive_\(UUID().uuidString)", isDirectory: true)
        let tempRoot = tempParent.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempParent) }

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
    /// extension wrote since the app was last opened gets missed. Moves the
    /// finished zip into the on-device backup library (Documents/Backups)
    /// rather than leaving it in tmp — that's what lets Restore list past
    /// backups by date instead of requiring the document picker every time.
    /// Prunes to the 2 most recent afterward, since each retained backup
    /// costs roughly the full size of your photos.
    @discardableResult
    static func buildFullBackup() throws -> URL {
        LocalReceiptStore.drainSpoolIntoDocuments()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let label = "ReceiptDrop_Backup_\(formatter.string(from: Date()))"
        let tempZipURL = try buildArchive(label: label, entries: SubmissionStore.loadHistory(), includeEverything: true)

        guard let backupsFolder = LocalReceiptStore.backupsFolderURL() else {
            return tempZipURL
        }
        let finalURL = backupsFolder.appendingPathComponent(tempZipURL.lastPathComponent)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempZipURL, to: finalURL)
        LocalReceiptStore.pruneBackups(keeping: 2)
        return finalURL
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

        // `.forUploading`-created zips contain the zipped folder itself as
        // their top-level entry, so the backup's files usually sit one
        // directory down from the extraction root. Accept either layout:
        // top-level, or nested in a single subfolder.
        var contentRoot = tempRoot
        if !FileManager.default.fileExists(atPath: contentRoot.appendingPathComponent("history.json").path) {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: contentRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let subdirs = children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            if subdirs.count == 1 { contentRoot = subdirs[0] }
        }

        let historyURL = contentRoot.appendingPathComponent("history.json")
        let manifestURL = contentRoot.appendingPathComponent("manifest.json")
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
                let sourceURL = contentRoot.appendingPathComponent(entry.category).appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                try? LocalReceiptStore.importFile(from: sourceURL, category: entry.category, filename: filename)
            }
        }

        for category in Set(backupEntries.map(\.category)) {
            let backupCSVURL = contentRoot.appendingPathComponent(category).appendingPathComponent("\(category)_log.csv")
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
    /// A `VendorType` raw value, classified once at save time (or later via
    /// the backfill action) and never re-derived at search time. Empty
    /// string means unclassified — manual entries, entries from before this
    /// field existed, or anything the model couldn't confidently place.
    var vendorType: String = ""

    init(id: UUID = UUID(), category: String, vendor: String, workDate: String, amount: String,
         receiptLink: String, timestamp: Date,
         verificationStatus: VerificationStatus = .none, reviewReason: String = "",
         extraFiles: [String] = [], vendorType: String = "") {
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
        self.vendorType = vendorType
    }

    // Custom Decodable so history persisted before these fields existed
    // (App Group UserDefaults) still decodes, defaulting to `.none`/empty.
    private enum CodingKeys: String, CodingKey {
        case id, category, vendor, workDate, amount, receiptLink, timestamp
        case verificationStatus, reviewReason, extraFiles, vendorType
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
        vendorType = try container.decodeIfPresent(String.self, forKey: .vendorType) ?? ""
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

/// One-time (re-runnable) maintenance action: classifies every history entry
/// still missing a `vendorType` — manual entries (never touched by any AI),
/// receipts saved before this field existed, or entries whose vendor was
/// renamed since (which resets the type, see `SubmissionPipeline.updateEntry`).
/// Safe to run anytime; only entries still empty get touched, and unique
/// vendor names are classified once each even if they appear on many receipts.
enum VendorTypeBackfillService {
    @discardableResult
    static func classifyUnclassified() async throws -> Int {
        let history = SubmissionStore.loadHistory()
        let unclassifiedVendors = Array(Set(
            history.filter { $0.vendorType.isEmpty && !$0.vendor.isEmpty }.map(\.vendor)))
        guard !unclassifiedVendors.isEmpty else { return 0 }

        let classifications = try await VendorTypeClassificationService.classify(vendorNames: unclassifiedVendors)
        guard !classifications.isEmpty else { return 0 }

        var updates: [HistoryEntry] = []
        for entry in history where entry.vendorType.isEmpty {
            guard let type = classifications[entry.vendor] else { continue }
            var updated = entry
            updated.vendorType = type
            updates.append(updated)
        }
        return SubmissionStore.updateHistoryEntries(updates)
    }
}
