import Foundation

/// Runs every *pending* Retry Queue entry (`QueueEntry.isPending == true`)
/// through `SubmissionPipeline` — called from the main app on
/// launch/foreground (see `ReceiptDropApp`). Pending entries are how the
/// share extension's multi-photo batch path hands work off to the main app:
/// the extension itself can only durably park bytes (`SubmissionStore.
/// enqueuePending`), because it can't safely run the AI round-trip inside
/// its own short, killable process lifetime (see
/// SHARE_EXTENSION_MULTI_RECEIPT_PLAN.md, "The critical constraint"). This
/// is the other half of that handoff: the first time the app is actually
/// open again, run the real extraction on whatever was parked.
///
/// Deliberately does NOT touch genuine failures (`isPending == false`) —
/// those already have their own manual Retry/Retry All UI in the Retry Queue
/// tab, and silently re-attempting them on every foreground would hammer a
/// failing network connection or a misconfigured API key repeatedly instead
/// of waiting for the user to notice and act.
enum PendingSubmissionProcessor {
    static func processPendingIfAny() {
        let pending = SubmissionStore.loadQueue().filter(\.isPending)
        guard !pending.isEmpty else { return }

        Task.detached(priority: .utility) {
            for entry in pending {
                guard let data = SubmissionStore.attachmentData(for: entry) else {
                    // File missing — nothing to process; drop the stale entry.
                    await MainActor.run { SubmissionStore.remove(entry) }
                    continue
                }
                do {
                    _ = try await SubmissionPipeline().run(data: data, kind: entry.kind, category: entry.category)
                    await MainActor.run { SubmissionStore.remove(entry) }
                } catch is SubmissionError {
                    // Already recorded (duplicate of something already in
                    // history) — nothing to save, nothing to retry.
                    await MainActor.run { SubmissionStore.remove(entry) }
                } catch {
                    // Now a genuine failure — replace the pending entry with
                    // a real failed one so it surfaces in the Retry Queue
                    // like any other failed submission, instead of silently
                    // vanishing or being retried forever on every foreground.
                    await MainActor.run {
                        SubmissionStore.remove(entry)
                        SubmissionStore.enqueue(data: data, category: entry.category, kind: entry.kind,
                                                error: error.localizedDescription)
                    }
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                }
            }
            LocalReceiptStore.drainSpoolIntoDocuments()
        }
    }
}
