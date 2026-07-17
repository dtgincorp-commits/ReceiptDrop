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
