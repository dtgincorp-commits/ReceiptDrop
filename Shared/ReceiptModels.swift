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

    init(id: UUID = UUID(), category: String, vendor: String, workDate: String, amount: String,
         receiptLink: String, timestamp: Date,
         verificationStatus: VerificationStatus = .none, reviewReason: String = "") {
        self.id = id
        self.category = category
        self.vendor = vendor
        self.workDate = workDate
        self.amount = amount
        self.receiptLink = receiptLink
        self.timestamp = timestamp
        self.verificationStatus = verificationStatus
        self.reviewReason = reviewReason
    }

    // Custom Decodable so history persisted before these fields existed
    // (App Group UserDefaults) still decodes, defaulting to `.none`.
    private enum CodingKeys: String, CodingKey {
        case id, category, vendor, workDate, amount, receiptLink, timestamp
        case verificationStatus, reviewReason
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
