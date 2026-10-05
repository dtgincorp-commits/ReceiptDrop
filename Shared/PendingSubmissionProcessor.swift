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
    /// Foreground path. Skips entries the user parked with "Save for Later"
    /// until they have waited out `QueueEntry.heldGracePeriod` — see
    /// `OvernightProcessingService` for the run that is meant to catch them
    /// first, and `heldLongEnoughToForce` for why this path still eventually
    /// does.
    static func processPendingIfAny() {
        processPending(SubmissionStore.loadQueue().filter {
            $0.isPending && (!$0.isHeld || $0.heldLongEnoughToForce)
        })
    }

    /// Overnight path: everything pending, held or not.
    ///
    /// `completion` fires when the queue is drained, so a `BGProcessingTask`
    /// can call `setTaskCompleted` at the right moment — a background task
    /// that never reports completion is killed and counts against the app's
    /// future scheduling.
    static func processAllPending(completion: (@Sendable () -> Void)? = nil) {
        processPending(SubmissionStore.loadQueue().filter(\.isPending),
                       completion: completion)
    }

    private static func processPending(_ pending: [QueueEntry],
                                       completion: (@Sendable () -> Void)? = nil) {
        guard !pending.isEmpty else {
            completion?()
            return
        }

        // DO NOT add a `ReceiptAllowance.canAdd` gate in this function.
        // Every entry here was already accepted at park time — the share
        // extension's `park(held:)` (see ShareSheetView.swift) is what
        // checks the free tier, and it does so *before* the bytes are
        // written to the queue. `ReceiptAllowance.used` already counts this
        // queue's contents (see its own doc comment on "closing the park
        // hole"), so the quota was already spent the moment this entry was
        // parked, not when it's drained here. Refusing it now — after the
        // user was already told "we've got it, we'll process it" by the
        // extension's park confirmation — would destroy a receipt the app
        // promised to save, for no gain: the slot is already spent either
        // way. If a future subscription lapse or counter bug ever makes this
        // look tempting, it is not the fix; the fix belongs at park time.

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
            completion?()
        }
    }
}
