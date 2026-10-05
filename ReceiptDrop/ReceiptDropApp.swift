import SwiftUI

@main
struct ReceiptDropApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // MUST be the very first thing this initializer does, before any
        // store is constructed. `resolveGrandfatheringIfNeeded()` reads
        // whether `categories` still equals `AppConstants.defaultCategories`
        // to decide if this install is fresh — but `CategoryStore.init`
        // seeds that same key with the same default the first time it runs
        // against an empty suite. If `CategoryStore.shared` (or anything
        // that touches it) ran even once before this call, a fresh install
        // would look identical to one that had always had the default
        // categories, which is still correctly "not grandfathered" — but
        // the ordering only stays correct by accident once something else
        // in the launch path starts writing to the suite before this does.
        // Calling this first, unconditionally, removes that race: the
        // grandfather decision is settled and frozen before anything else
        // in this process (or, thanks to `resolveGrandfatheringIfNeeded`'s
        // own idempotency guard, in the share extension) can perturb the
        // signals it reads.
        ReceiptAllowance.resolveGrandfatheringIfNeeded()
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
                .task {
                    // Loads the product, refreshes the cached entitlement the
                    // share extension reads, and starts the `Transaction.updates`
                    // listener for the app's whole lifetime — see
                    // `SubscriptionService.start()`'s own comment. `.task` on
                    // the root view rather than a one-shot call in `init()`
                    // because `start()` kicks off async work (product load,
                    // an `await` loop over `Transaction.updates`); `init()`
                    // is synchronous and isn't the right place to fire async
                    // work that outlives it.
                    SubscriptionService.shared.start()
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
                // Re-derive the entitlement on every foreground, not just at
                // launch — a subscription bought, renewed, or cancelled while
                // this app was backgrounded (e.g. via Settings > Apple ID >
                // Subscriptions) should update the cached snapshot the share
                // extension trusts without requiring a full relaunch.
                Task { await SubscriptionService.shared.refreshEntitlements() }
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
