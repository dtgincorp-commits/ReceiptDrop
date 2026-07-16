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
