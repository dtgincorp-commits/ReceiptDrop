import SwiftUI

@main
struct ReceiptDropApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep receipt images off iCloud/device backups — enforce, don't just
        // advise. Runs every launch so the flag survives folder recreation.
        LocalReceiptStore.excludeReceiptsFromBackup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // `onOpenURL` is a View modifier, not a Scene one — it has to
                // sit on the content, not chained onto WindowGroup itself.
                // The share extension's "open the main app" link (see
                // ShareSheetView) uses this scheme purely to bring the app to
                // the foreground — there's no path/query payload to route on,
                // so landing on the normal ContentView is already the whole
                // job.
                .onOpenURL { _ in }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                AutoBackupService.runIfDueOnForeground()
                // Picks up anything the share extension's multi-photo batch
                // path parked but couldn't safely extract itself (see
                // PendingSubmissionProcessor / SubmissionStore.enqueuePending).
                PendingSubmissionProcessor.processPendingIfAny()
                // Hashes anything still missing a `fileHash` so the
                // identical-file duplicate signal covers it. Self-healing by
                // design rather than a Settings button — see
                // `runOnForeground`'s comment for why that button was
                // removed. No-ops within milliseconds once everything is
                // hashed, which is the normal case on every launch after the
                // first.
                ReceiptHashBackfillService.runOnForeground()
            case .background:
                AutoBackupService.attemptBestEffortBackupOnBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
