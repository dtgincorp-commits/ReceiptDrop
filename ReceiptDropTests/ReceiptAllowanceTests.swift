import XCTest
@testable import ReceiptDrop

/// Covers `ReceiptAllowance` — the free-tier (25 receipts, lifetime) gate
/// described in `SUBSCRIPTION_PLAN.md`.
///
/// The risk this guards against isn't a UI bug, it's money: undercounting
/// lets people scan forever for free, overcounting walls a grandfathered or
/// paying user out of a feature they're entitled to. Both directions matter
/// here, which is why this suite checks the counter's monotonicity and the
/// two "never charge/never wall" exemptions (Restore, subscribed/grandfathered)
/// as carefully as the happy path.
final class ReceiptAllowanceTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!

    override func setUp() {
        super.setUp()
        ReceiptAllowance.resetForTesting()
        clearHistoryAndQueue()
        // Freeze grandfathering to "not grandfathered" for every test unless
        // a test explicitly wants the opposite — otherwise a fresh-install
        // state (no history, no categories key written yet, etc.) could
        // legitimately resolve either way depending on suite ordering.
        defaults.set(false, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
    }

    override func tearDown() {
        ReceiptAllowance.resetForTesting()
        clearHistoryAndQueue()
        super.tearDown()
    }

    private func clearHistoryAndQueue() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.history)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.retryQueue)
    }

    private func makeEntry(amount: String = "10.00") -> HistoryEntry {
        HistoryEntry(category: "BUSINESS EXPENSES", vendor: "Test Vendor",
                     workDate: "2026-01-01", amount: amount,
                     receiptLink: SubmissionPipeline.manualEntryLabel, timestamp: Date())
    }

    // MARK: - Fresh install

    func testFreshInstallHas25Remaining() {
        XCTAssertEqual(ReceiptAllowance.remaining, 25)
        XCTAssertTrue(ReceiptAllowance.canAdd(1))
        XCTAssertFalse(ReceiptAllowance.canAdd(26))
    }

    // MARK: - Monotonicity

    func testCounterIsMonotonicAcrossDeletes() {
        let entries = [makeEntry(amount: "1"), makeEntry(amount: "2"), makeEntry(amount: "3")]
        for entry in entries { SubmissionStore.appendHistory(entry) }
        XCTAssertEqual(ReceiptAllowance.used, 3)

        for entry in entries { SubmissionStore.removeHistory(entry) }
        // Deleting receipts must not refund quota — see the plan's "scan 25,
        // delete 25, scan 25 more, forever" scenario this exists to prevent.
        XCTAssertEqual(ReceiptAllowance.used, 3)
    }

    // MARK: - Restore

    func testRestoreDoesNotConsumeQuota() {
        let entries = (0..<40).map { makeEntry(amount: "\($0)") }
        let added = SubmissionStore.mergeHistory(entries)
        XCTAssertEqual(added, 40)
        XCTAssertEqual(ReceiptAllowance.used, 0)
        XCTAssertEqual(ReceiptAllowance.remaining, 25)
    }

    // MARK: - The park hole

    func testPendingQueueCountsTowardUsed() {
        SubmissionStore.enqueuePending(data: Data([1, 2, 3]), category: "BUSINESS EXPENSES", kind: .image)
        SubmissionStore.enqueuePending(data: Data([4, 5, 6]), category: "BUSINESS EXPENSES", kind: .image)
        XCTAssertEqual(ReceiptAllowance.used, 2)
        XCTAssertEqual(ReceiptAllowance.remaining, 23)

        // Clean up the parked files this test created.
        for entry in SubmissionStore.loadQueue() { SubmissionStore.remove(entry) }
    }

    // MARK: - Grandfathering

    func testGrandfatheredUserIsUnlimitedRegardlessOfCounter() {
        defaults.set(true, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        for i in 0..<30 { SubmissionStore.appendHistory(makeEntry(amount: "\(i)")) }
        XCTAssertTrue(ReceiptAllowance.isUnlimited)
        XCTAssertEqual(ReceiptAllowance.remaining, .max)
        XCTAssertTrue(ReceiptAllowance.canAdd(1000))
    }

    func testGrandfatherResolutionIsFrozenOnceResolvedTrue() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        // A prior-install signal: non-empty history.
        SubmissionStore.appendHistory(makeEntry())
        ReceiptAllowance.resolveGrandfatheringIfNeeded()
        XCTAssertTrue(defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered))

        // Clearing history afterwards must not un-grandfather the user —
        // resolution only ever happens once.
        clearHistoryAndQueue()
        XCTAssertTrue(ReceiptAllowance.isUnlimited)
    }

    func testGrandfatherResolutionOnFreshInstallIsNotGrandfathered() {
        // Preserve whatever CategoryStore.shared (a process-wide singleton
        // other test files also touch) already wrote to the suite, so this
        // test doesn't leave later tests in this run without a categories
        // key on disk.
        let existingCategories = defaults.stringArray(forKey: AppConstants.DefaultsKeys.categories)
        defer {
            if let existingCategories {
                defaults.set(existingCategories, forKey: AppConstants.DefaultsKeys.categories)
            }
        }

        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.categories)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.lastBackupDate)
        clearHistoryAndQueue()

        ReceiptAllowance.resolveGrandfatheringIfNeeded()
        XCTAssertFalse(defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered))
    }

    // MARK: - Grandfathering: the "categories key exists" trap

    /// Regression test for the bug fixed alongside this test: the old logic
    /// treated "the `categories` key exists in the suite" as proof of a
    /// prior install. But `CategoryStore.init` seeds that exact key with
    /// `AppConstants.defaultCategories` the first time it runs against an
    /// empty suite, and `CategoryStore` is constructed at app launch — so
    /// the key exists within moments of a brand-new install's first launch,
    /// before the user has done anything. Against the old logic this
    /// install — categories present but identical to the untouched seed,
    /// nothing else present — would have resolved `true` (grandfathered).
    /// It must resolve `false`. If this test fails, the trap has come back.
    func testFreshInstallWithSeededDefaultCategoriesIsNotGrandfathered() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.lastBackupDate)
        clearHistoryAndQueue()
        // Simulate exactly what `CategoryStore.init` does on a fresh suite:
        // seed `categories` with the untouched default, nothing more.
        defaults.set(AppConstants.defaultCategories, forKey: AppConstants.DefaultsKeys.categories)

        ReceiptAllowance.resolveGrandfatheringIfNeeded()
        XCTAssertFalse(defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered),
                       "A seeded-but-untouched `categories` key must not, by itself, look like a prior install.")
    }

    /// The flip side: categories that actually diverge from the seed —
    /// i.e. the user added, renamed, or removed one — IS real evidence of a
    /// prior install, even with every other signal absent.
    func testCustomizedCategoriesAloneIsGrandfathered() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.lastBackupDate)
        clearHistoryAndQueue()
        defaults.set(AppConstants.defaultCategories + ["OFFICE SUPPLIES"], forKey: AppConstants.DefaultsKeys.categories)

        ReceiptAllowance.resolveGrandfatheringIfNeeded()
        XCTAssertTrue(defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered))
    }

    /// A non-empty retry queue alone — nothing saved to history yet, just a
    /// failed or pending submission sitting there — is also real evidence of
    /// a prior install.
    func testNonEmptyRetryQueueAloneIsGrandfathered() {
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.lastBackupDate)
        defaults.removeObject(forKey: AppConstants.DefaultsKeys.categories)
        clearHistoryAndQueue()
        SubmissionStore.enqueue(data: Data([1, 2, 3]), category: "BUSINESS EXPENSES", kind: .image, error: "network error")

        ReceiptAllowance.resolveGrandfatheringIfNeeded()
        XCTAssertTrue(defaults.bool(forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered))

        // Clean up the parked file this test created.
        for entry in SubmissionStore.loadQueue() { SubmissionStore.remove(entry) }
    }

    // MARK: - Subscribed (cached)

    func testSubscribedCachedUserIsUnlimitedAndRecordUseDoesNotIncrement() {
        ReceiptAllowance.updateEntitlementCache(isSubscribed: true, expiry: Date().addingTimeInterval(86_400))
        XCTAssertTrue(ReceiptAllowance.isUnlimited)
        XCTAssertEqual(ReceiptAllowance.remaining, .max)

        SubmissionStore.appendHistory(makeEntry())
        XCTAssertEqual(defaults.integer(forKey: AppConstants.DefaultsKeys.freeReceiptsUsed), 0,
                       "A subscribed user's underlying counter must not move — it's the fallback if the subscription lapses.")
    }
}
