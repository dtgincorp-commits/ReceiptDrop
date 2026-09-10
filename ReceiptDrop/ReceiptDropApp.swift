import SwiftUI

@main
struct ReceiptDropApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep receipt images off iCloud/device backups — enforce, don't just
        // advise. Runs every launch so the flag survives folder recreation.
        LocalReceiptStore.excludeReceiptsFromBackup()
        // Must happen before the app finishes launching — BGTaskScheduler
        // rejects a registration made any later.
        OvernightProcessingService.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // `onOpenURL` is a View modifier, not a Scene one — it has to
                // sit on the content, not chained onto WindowGroup itself.
                // The share extension opens this scheme after every save
                // (see ShareSheetView's `onFinish`) with a host naming where
                // the receipt went, so the user lands there instead of just
                // being dropped back into ContentView with no evidence
                // anything happened. The first-run "set up the app" link
                // still opens the bare scheme with no host — for that one,
                // and for anything else unrecognized, simply coming to the
                // foreground on the normal ContentView is already the whole
                // job, same as before this existed.
                .onOpenURL { url in
                    switch url.host {
                    case AppConstants.DeepLinkHost.receipts:
                        ReceiptsNavigator.shared.selectedTab = 0
                    case AppConstants.DeepLinkHost.pending:
                        ReceiptsNavigator.shared.showPending()
                    default:
                        break
                    }
                }
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
                // Receipts parked by the share extension's "Save for Later"
                // are read overnight rather than on next open. No-ops when
                // nothing is held.
                OvernightProcessingService.scheduleIfNeeded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
