import Foundation

/// Enforces the free tier (25 receipts, lifetime) described in
/// `SUBSCRIPTION_PLAN.md`. Lives in `Shared/` — compiled into both the main
/// app and the share extension — because the App Group suite backing it is
/// how both processes agree on one number without a server.
///
/// This is the read side only. The one place that *writes* the counter is
/// `SubmissionStore.appendHistory` (see its doc comment) — every ingest path
/// converges there, so this type never needs its own hook into any of the
/// half-dozen places a receipt can originate from.
enum ReceiptAllowance {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    /// True once the user is exempt from the wall entirely — grandfathered
    /// in from before this feature existed, or currently subscribed per the
    /// cached entitlement. Checked before `used`/`remaining` even look at the
    /// counter, since neither of those numbers matters once this is true.
    static var isUnlimited: Bool {
        resolveGrandfatheringIfNeeded()
        return isGrandfathered || cachedIsSubscribed
    }

    /// Split out from `isUnlimited` for Settings, which needs to tell the
    /// two exemptions apart in its copy: a grandfathered user gets an honest
    /// "thanks for being an early user" with no counter and no upsell, while
    /// a subscribed user gets a plan name and renewal date. `isUnlimited`
    /// itself has no reason to distinguish them — both mean "skip the wall"
    /// — so this stays a separate, narrower accessor rather than changing
    /// what `isUnlimited` returns.
    static var isGrandfathered: Bool {
        resolveGrandfatheringIfNeeded()
        return defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
    }

    /// How many of the free allowance this install has consumed.
    ///
    /// Deliberately `freeReceiptsUsed + SubmissionStore.loadQueue().count`,
    /// not just the counter — this is "closing the park hole" from the plan.
    /// The share extension doesn't save receipts, it *parks* them
    /// (`SubmissionStore.enqueuePending`/`enqueueHeld`) for the main app to
    /// drain later via `PendingSubmissionProcessor`, and nothing increments
    /// `freeReceiptsUsed` at park time. Without counting the queue here, a
    /// single share-sheet session could park an unbounded batch — each one
    /// checked against the *same* unconsumed `freeReceiptsUsed` value — and
    /// only run out of room once the main app actually drained them, long
    /// after the user was told every one of them was accepted.
    static var used: Int {
        resolveGrandfatheringIfNeeded()
        return defaults.integer(forKey: AppConstants.DefaultsKeys.freeReceiptsUsed) + SubmissionStore.loadQueue().count
    }

    /// Slots left before the wall, or `Int.max` for an unlimited account —
    /// `Int.max` rather than some sentinel like `-1` so callers that just do
    /// arithmetic on this (e.g. "you have \(remaining) left") never need a
    /// separate unlimited check to avoid printing a negative number.
    static var remaining: Int {
        isUnlimited ? Int.max : max(0, AppConstants.freeReceiptLimit - used)
    }

    /// Whether `count` more receipts (default 1) would still fit under the
    /// limit. Always true when unlimited, so callers can gate a batch
    /// (`canAdd(batchSize)`) without special-casing subscribed/grandfathered
    /// users themselves.
    static func canAdd(_ count: Int = 1) -> Bool {
        isUnlimited || used + count <= AppConstants.freeReceiptLimit
    }

    /// Records that one receipt landed in history. Called from exactly one
    /// place — `SubmissionStore.appendHistory` — never from `mergeHistory`
    /// (Restore), which must not consume quota.
    ///
    /// No-op when unlimited: a subscriber or grandfathered user's counter is
    /// left exactly where it was rather than incremented and ignored. That
    /// matters for the day a subscription lapses — the fallback then is
    /// whatever `freeReceiptsUsed` legitimately was before the sub started,
    /// not an inflated count that silently walls someone who never actually
    /// used their free 25.
    static func recordUse() {
        guard !isUnlimited else { return }
        let current = defaults.integer(forKey: AppConstants.DefaultsKeys.freeReceiptsUsed)
        defaults.set(current + 1, forKey: AppConstants.DefaultsKeys.freeReceiptsUsed)
    }

    // MARK: - Grandfathering

    /// Decides, once, whether this install predates the free tier and should
    /// never see the wall. Idempotent by design: if `subscriptionGrandfathered`
    /// is already present in the suite, this returns immediately without
    /// re-deriving anything.
    ///
    /// Called lazily from the top of `isUnlimited`/`used` (rather than only
    /// from an explicit app-launch hook) so that whichever process — main app
    /// or share extension — happens to ask first resolves it, and resolves it
    /// identically, since both read the same four signals from the same App
    /// Group suite. Also safe to call explicitly and early (e.g. at app
    /// launch) to warm the value before the UI needs it; the guard makes a
    /// double call harmless.
    ///
    /// Never recomputed after that first write — seeing a stored value (true
    /// or false) always short-circuits. Re-deriving on every call would flip
    /// an existing user out of grandfathered status the moment they cleared
    /// their history, which is exactly the bug this guards against.
    static func resolveGrandfatheringIfNeeded() {
        guard defaults.object(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered) == nil else { return }

        // Five independent signals, any one of which proves an install
        // existed before this feature shipped. See SUBSCRIPTION_PLAN.md for
        // the accepted edge case (an install that never scanned, never
        // configured AI, never customized Categories, and never backed up or
        // retried anything is indistinguishable from fresh and gets the
        // 25-receipt tier — it has no receipts to lose).
        //
        // TRAP, hit once already: "the `categories` key exists in the suite"
        // looks like a fourth signal but is NOT one. `CategoryStore.init`
        // (Shared/CategoryStore.swift) writes `AppConstants.defaultCategories`
        // into that exact key the very first time it runs against an empty
        // suite — and `CategoryStore` is constructed at app launch. So on a
        // brand-new install the key exists within moments of first launch,
        // before the user has scanned anything, completed AI setup, or
        // touched Categories at all. Checking mere presence of the key would
        // have resolved *every* new user as grandfathered — unlimited
        // receipts free, paywall never shown, the entire feature earning
        // nothing. The only thing that actually proves a prior install is
        // the categories having *diverged* from the seed, i.e. the user
        // deliberately added, renamed, or removed one.
        //
        // Anyone adding a new signal to this list later: apply the same
        // test CategoryStore failed — "could a fresh install, with zero user
        // action, trip this on its own just by launching?" If yes, it is not
        // a valid signal.
        let hasHistory = !SubmissionStore.loadHistory().isEmpty
        let hasCompletedAISetup = defaults.bool(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        let hasBackedUp = defaults.object(forKey: AppConstants.DefaultsKeys.lastBackupDate) != nil
        let hasRetryQueue = !SubmissionStore.loadQueue().isEmpty
        let savedCategories = defaults.stringArray(forKey: AppConstants.DefaultsKeys.categories)
        let hasCustomizedCategories = savedCategories != nil && savedCategories! != AppConstants.defaultCategories

        let grandfathered = hasHistory || hasCompletedAISetup || hasBackedUp || hasRetryQueue || hasCustomizedCategories
        defaults.set(grandfathered, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
    }

    // MARK: - Entitlement cache (written by the app, read by both)

    /// The main app's last-known subscription status, mirrored into the App
    /// Group suite so the share extension — which never calls StoreKit, see
    /// `SubscriptionService` — can still honor an active subscription.
    ///
    /// Deliberately fail-open on staleness: this returns whatever was last
    /// written even if `entitlementCheckedAt` is old, rather than reverting
    /// to "not subscribed" after some freshness window. The alternative —
    /// distrusting a stale cache — means a paying customer who hasn't opened
    /// the main app in a while gets walled inside a share sheet with no way
    /// to fix it from there (no purchase UI in the extension, by design). A
    /// brief over-grant to a lapsed subscriber is the cheaper mistake.
    static var cachedIsSubscribed: Bool {
        defaults.bool(forKey: AppConstants.DefaultsKeys.isSubscribed)
    }

    static var cachedExpiry: Date? {
        defaults.object(forKey: AppConstants.DefaultsKeys.subscriptionExpiry) as? Date
    }

    /// Called by `SubscriptionService` (main app only) after every StoreKit
    /// resolution — initial load, `Transaction.updates`, restore — so the
    /// cache the extension reads is never more than one launch/foreground
    /// behind reality.
    static func updateEntitlementCache(isSubscribed: Bool, expiry: Date?) {
        defaults.set(isSubscribed, forKey: AppConstants.DefaultsKeys.isSubscribed)
        if let expiry {
            defaults.set(expiry, forKey: AppConstants.DefaultsKeys.subscriptionExpiry)
        } else {
            defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionExpiry)
        }
        defaults.set(Date(), forKey: AppConstants.DefaultsKeys.entitlementCheckedAt)
    }

    // MARK: - Testing

    /// Test-only. Clears every key this type owns so each test starts from a
    /// fresh-install state. Never call this from app or extension code.
    static func resetForTesting() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.freeReceiptsUsed)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.isSubscribed)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionExpiry)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.entitlementCheckedAt)
    }

    #if DEBUG
    /// Settings' Purchase Testing section: jumps the free-tier counter so a
    /// device can reach the paywall without filing 25 real receipts. Compiled
    /// out of release builds.
    static func debugSetFreeReceiptsUsed(_ count: Int) {
        defaults.set(count, forKey: AppConstants.DefaultsKeys.freeReceiptsUsed)
    }
    #endif
}
