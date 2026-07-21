import Foundation

/// Thrown by `SubmissionPipeline` when a receipt looks like one already
/// recorded (same category, date, and amount) — callers should treat this as
/// "nothing to do" rather than a failure to retry.
enum SubmissionError: LocalizedError {
    case duplicate(HistoryEntry)

    var errorDescription: String? {
        switch self {
        case .duplicate(let entry):
            let vendor = entry.vendor.isEmpty ? "this vendor" : entry.vendor
            return "Already submitted as \(vendor) on \(entry.workDate) for $\(entry.amount)."
        }
    }
}

/// The end-to-end submission: Claude extraction → local save → history entry.
/// Lives in Shared so the share extension runs it for new submissions and the
/// main app reuses it for retries.
///
/// On success it records a `HistoryEntry` and returns it. On failure it throws;
/// callers decide whether to queue the bytes for retry (the extension does).
/// Throws `SubmissionError.duplicate` instead of saving again if a history
/// entry with the same category/date/amount already exists — repeated OCR
/// noise in the vendor name (or a slightly re-encoded image) shouldn't create
/// duplicate files and CSV rows for what's clearly the same receipt.
struct SubmissionPipeline {
    /// Written to the CSV's Receipt_File column (and HistoryEntry.receiptLink)
    /// for entries with no scanned file — lets the row explain itself instead
    /// of just being blank.
    static let manualEntryLabel = "Manual Data Entry"

    /// Same idea as `manualEntryLabel`, for entries submitted via the Live
    /// Text scanner (VisionKit's `DataScannerViewController`) — recognized
    /// text only, no photo was ever taken.
    static let scannedTextLabel = "Scanned Text"

    /// True for either placeholder — used by the UI to know there's no file
    /// to preview.
    static func isPlaceholderLabel(_ label: String) -> Bool {
        label == manualEntryLabel || label == scannedTextLabel
    }

    /// Stages reported to the UI so it can show progress.
    enum Stage {
        case reading
        case saving

        var statusText: String {
            switch self {
            case .reading: return "Reading receipt…"
            case .saving: return "Saving…"
            }
        }
    }

    /// Runs the pipeline. `onStage` is invoked on the main actor before each
    /// stage so the caller can drive a progress label.
    @discardableResult
    func run(data: Data,
             kind: ReceiptKind,
             category: String,
             onStage: @MainActor (Stage) -> Void = { _ in }) async throws -> HistoryEntry {
        await onStage(.reading)
        let categoryContext = CategoryStore.shared.description(for: category)
        let extracted = try await Self.extractWithFallback(data: data, kind: kind, categoryContext: categoryContext)

        if let existing = SubmissionStore.loadHistory().first(where: {
            $0.category == category && $0.workDate == extracted.workDate && $0.amount == extracted.amount
        }) {
            throw SubmissionError.duplicate(existing)
        }

        await onStage(.saving)
        let filename = try LocalReceiptStore.save(data: data, category: category, kind: kind)
        try LocalReceiptStore.appendLog(
            vendor: extracted.vendor, workDate: extracted.workDate, amount: extracted.amount,
            comments: extracted.comments, receiptFilename: filename, category: category)

        let entry = HistoryEntry(
            category: category,
            vendor: extracted.vendor,
            workDate: extracted.workDate,
            amount: extracted.amount,
            receiptLink: filename,
            timestamp: Date(),
            verificationStatus: extracted.needsReview ? .needsReview : .none,
            reviewReason: extracted.reviewReason,
            vendorType: extracted.vendorType)
        SubmissionStore.appendHistory(entry)
        return entry
    }

    /// Runs extraction using the currently-selected provider/mode. In
    /// "On-Device OCR Text" mode, images are OCR'd on-device first (free,
    /// no network) and only the recognized text goes to the AI provider —
    /// but if the OCR text is suspiciously short (camera caught nothing
    /// useful) or the resulting extraction comes back flagged `needsReview`,
    /// this automatically retries once with the full image, keeping whichever
    /// result that retry produces. PDFs and "Full Image" mode always send the
    /// full file, unaffected by this fallback.
    private static func extractWithFallback(data: Data, kind: ReceiptKind, categoryContext: String) async throws -> ExtractedReceipt {
        try ExtractionSettings.assertProviderAllowed()
        let extractor = ExtractionSettings.currentExtractor()
        guard kind == .image, ExtractionSettings.mode == .onDeviceOCR else {
            return try await extractor.extract(data: data, kind: kind, categoryContext: categoryContext)
        }

        let ocrText = (try? await VisionOCRService.recognizeText(in: data)) ?? ""
        guard ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            return try await extractor.extract(data: data, kind: kind, categoryContext: categoryContext)
        }

        let fromText = try await extractor.extract(ocrText: ocrText, categoryContext: categoryContext)
        guard fromText.needsReview else { return fromText }
        return (try? await extractor.extract(data: data, kind: kind, categoryContext: categoryContext)) ?? fromText
    }

    /// Records a receipt with no photo/PDF attached — the user typed the
    /// details in by hand. Same duplicate check and CSV/history bookkeeping
    /// as `run`, just skipping Claude extraction and the file save.
    @discardableResult
    static func recordManualEntry(vendor: String, workDate: String, amount: String,
                                  comments: String, category: String) throws -> HistoryEntry {
        if let existing = SubmissionStore.loadHistory().first(where: {
            $0.category == category && $0.workDate == workDate && $0.amount == amount
        }) {
            throw SubmissionError.duplicate(existing)
        }

        try LocalReceiptStore.appendLog(
            vendor: vendor, workDate: workDate, amount: amount,
            comments: comments, receiptFilename: Self.manualEntryLabel, category: category)

        let entry = HistoryEntry(
            category: category, vendor: vendor, workDate: workDate, amount: amount,
            receiptLink: Self.manualEntryLabel, timestamp: Date(),
            verificationStatus: .verified)
        SubmissionStore.appendHistory(entry)
        return entry
    }

    /// Records a receipt read via the Live Text scanner — Claude reads text
    /// already recognized on-device (VisionKit), and no photo is saved, same
    /// as `recordManualEntry` but auto-filled by Claude instead of typed in.
    @discardableResult
    func runTextOnly(ocrText: String, category: String,
                     onStage: @MainActor (Stage) -> Void = { _ in }) async throws -> HistoryEntry {
        await onStage(.reading)
        try ExtractionSettings.assertProviderAllowed()
        let categoryContext = CategoryStore.shared.description(for: category)
        let extracted = try await ExtractionSettings.currentExtractor().extract(ocrText: ocrText, categoryContext: categoryContext)

        if let existing = SubmissionStore.loadHistory().first(where: {
            $0.category == category && $0.workDate == extracted.workDate && $0.amount == extracted.amount
        }) {
            throw SubmissionError.duplicate(existing)
        }

        try LocalReceiptStore.appendLog(
            vendor: extracted.vendor, workDate: extracted.workDate, amount: extracted.amount,
            comments: extracted.comments, receiptFilename: Self.scannedTextLabel, category: category)

        let entry = HistoryEntry(
            category: category, vendor: extracted.vendor, workDate: extracted.workDate,
            amount: extracted.amount, receiptLink: Self.scannedTextLabel, timestamp: Date(),
            verificationStatus: extracted.needsReview ? .needsReview : .none,
            reviewReason: extracted.reviewReason, vendorType: extracted.vendorType)
        SubmissionStore.appendHistory(entry)
        return entry
    }

    /// Edits an existing entry in place: rewrites the History entry and its
    /// CSV row with the new field values, and reconciles the underlying file:
    /// a new photo replaces the old one, a category change with no new photo
    /// moves the existing file to the new category's folder, and otherwise
    /// the file (or lack of one, for manual/scanned-text entries) is left as-is.
    @discardableResult
    static func updateEntry(old: HistoryEntry,
                           newCategory: String, newVendor: String, newWorkDate: String,
                           newAmount: String, newComments: String,
                           newVendorType: String? = nil,
                           newPhoto: (data: Data, kind: ReceiptKind)? = nil,
                           newExtraPhotos: [(data: Data, kind: ReceiptKind)] = [],
                           removedExtraFiles: [String] = []) throws -> HistoryEntry {
        var finalFilename = old.receiptLink

        if let newPhoto {
            finalFilename = try LocalReceiptStore.save(data: newPhoto.data, category: newCategory, kind: newPhoto.kind)
            if !isPlaceholderLabel(old.receiptLink),
               let oldURL = LocalReceiptStore.existingFileURL(category: old.category, filename: old.receiptLink) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        } else if !isPlaceholderLabel(old.receiptLink), old.category != newCategory {
            try LocalReceiptStore.moveFile(filename: old.receiptLink, from: old.category, to: newCategory)
        }

        // Extra attachments: drop removed ones, move survivors if the
        // category changed, then save any newly-added photos into place.
        var remainingExtras: [String] = []
        for filename in old.extraFiles {
            if removedExtraFiles.contains(filename) {
                if let url = LocalReceiptStore.existingFileURL(category: old.category, filename: filename) {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            if old.category != newCategory {
                try LocalReceiptStore.moveFile(filename: filename, from: old.category, to: newCategory)
            }
            remainingExtras.append(filename)
        }
        for extraPhoto in newExtraPhotos {
            let filename = try LocalReceiptStore.save(data: extraPhoto.data, category: newCategory, kind: extraPhoto.kind)
            remainingExtras.append(filename)
        }

        try LocalReceiptStore.removeRow(
            category: old.category, vendor: old.vendor, workDate: old.workDate,
            amount: old.amount, receiptFilename: old.receiptLink)
        try LocalReceiptStore.appendLog(
            vendor: newVendor, workDate: newWorkDate, amount: newAmount, comments: newComments,
            receiptFilename: finalFilename, category: newCategory,
            scannedDate: LocalReceiptStore.dateString(old.timestamp))

        // If the vendor name changed and the caller didn't explicitly pick a
        // new type (i.e. the Type picker was left showing the old value),
        // the stored type is now stale — clear it so it gets picked up by
        // the next "Classify Untyped Receipts" run rather than silently
        // keeping a type that belonged to the old vendor name.
        let vendorChanged = newVendor != old.vendor
        let resolvedVendorType: String
        if let newVendorType {
            resolvedVendorType = (vendorChanged && newVendorType == old.vendorType) ? "" : newVendorType
        } else {
            resolvedVendorType = vendorChanged ? "" : old.vendorType
        }

        // A human just reviewed and saved this entry through Edit — clears
        // any HITL flag and marks it permanently verified, regardless of
        // whether it was flagged going in.
        let updated = HistoryEntry(
            id: old.id, category: newCategory, vendor: newVendor, workDate: newWorkDate,
            amount: newAmount, receiptLink: finalFilename, timestamp: old.timestamp,
            verificationStatus: .verified, extraFiles: remainingExtras, vendorType: resolvedVendorType)
        SubmissionStore.updateHistory(updated)
        return updated
    }
}
