import Foundation
import UIKit

extension Notification.Name {
    /// Posted whenever a background batch submission saves, fails, or
    /// finishes — lets `ReceiptsView` refresh live instead of only on
    /// next appear/foreground.
    static let receiptDropDidUpdateHistory = Notification.Name("ReceiptDrop.didUpdateHistory")
}

/// Runs a batch of independent photo submissions without being tied to any
/// view's lifetime — started from `BatchReceiptSubmitView`, which dismisses
/// immediately after kicking this off so the user isn't stuck watching a
/// "2 of 5" progress screen. Each photo still goes through the same
/// `SubmissionPipeline` used everywhere else: successes save quietly,
/// duplicates are skipped, and genuine failures land in the retry queue —
/// exactly like a single submission, just looped and detached from the UI.
enum BatchSubmissionRunner {
    static func submit(attachments: [SharedAttachment], category: String) {
        Task.detached(priority: .userInitiated) {
            for attachment in attachments {
                let kind: ReceiptKind = attachment.kind == .image ? .image : .pdf
                let data: Data
                if attachment.kind == .image, let jpeg = UIImage(data: attachment.data)?.jpegData(compressionQuality: 0.85) {
                    data = jpeg
                } else {
                    data = attachment.data
                }

                do {
                    _ = try await SubmissionPipeline().run(data: data, kind: kind, category: category) { _ in }
                } catch is SubmissionError {
                    // Already recorded — nothing to save, nothing to retry.
                } catch {
                    SubmissionStore.enqueue(data: data, category: category, kind: kind,
                                            error: error.localizedDescription)
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                }
            }
            LocalReceiptStore.drainSpoolIntoDocuments()
        }
    }
}
