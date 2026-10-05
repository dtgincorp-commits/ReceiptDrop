import XCTest
import StoreKit
import StoreKitTest
@testable import ReceiptDrop

/// The whole purchase flow against `Products.storekit`, driven through
/// StoreKitTest instead of taps: no Apple account, no money, no dialogs.
/// Exercises the app's own `SubscriptionService` and `ReceiptAllowance` —
/// the code a real purchase runs through — not a reimplementation.
///
/// What it can't cover is App Store Connect itself (the real product, price
/// and agreements); that is the sandbox test on a device. See
/// RELEASE_CHECKLIST.md.
@MainActor
final class SubscriptionPurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private var service: SubscriptionService { SubscriptionService.shared }

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        ReceiptAllowance.resetForTesting()
        defaults.set(false, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        service.start()
        try await waitUntil("product loads") { self.service.product != nil }
        await service.refreshEntitlements()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        await service.refreshEntitlements()
        ReceiptAllowance.resetForTesting()
    }

    /// StoreKit delivers some results (Ask to Buy approval, renewals) on its
    /// own schedule; poll rather than sleep a fixed time.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting: \(what)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The test session applies an expiry or refund asynchronously, so
    /// re-derive entitlement until it lands — the same refresh the app runs
    /// on every launch and on every `Transaction.updates` event.
    private func refreshUntilNotSubscribed() async throws {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            await service.refreshEntitlements()
            if !service.isSubscribed { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        XCTFail("still subscribed 10 seconds after the subscription ended")
    }

    private func useUpFreeReceipts() {
        for _ in 0..<AppConstants.freeReceiptLimit { ReceiptAllowance.recordUse() }
    }

    // MARK: - The product

    func testTheProductIsTheYearlySubscriptionAtTheAgreedPrice() throws {
        let product = try XCTUnwrap(service.product)
        XCTAssertEqual(product.id, AppConstants.proYearlyProductID)
        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertEqual(product.price, Decimal(string: "7.99"))
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
    }

    // MARK: - Free tier

    func testTheFreeTierStopsAtTheLimit() {
        XCTAssertEqual(AppConstants.freeReceiptLimit, 25)
        for _ in 0..<24 { ReceiptAllowance.recordUse() }
        XCTAssertTrue(ReceiptAllowance.canAdd(), "receipt 25 is still free")
        ReceiptAllowance.recordUse()
        XCTAssertFalse(ReceiptAllowance.canAdd(), "receipt 26 hits the paywall")
        XCTAssertEqual(ReceiptAllowance.remaining, 0)
    }

    // MARK: - Buying

    func testBuyingUnlocksUnlimitedReceipts() async throws {
        useUpFreeReceipts()
        XCTAssertFalse(ReceiptAllowance.canAdd())

        try await service.purchase()

        XCTAssertTrue(service.isSubscribed)
        XCTAssertTrue(ReceiptAllowance.isUnlimited)
        XCTAssertTrue(ReceiptAllowance.canAdd(1000))
        XCTAssertTrue(ReceiptAllowance.cachedIsSubscribed, "the share extension reads this cache")
        let expiry = try XCTUnwrap(ReceiptAllowance.cachedExpiry)
        XCTAssertGreaterThan(expiry, Date())
    }

    func testAFailedPurchaseLeavesTheFreeTierInPlace() async {
        useUpFreeReceipts()
        session.failTransactionsEnabled = true

        do {
            try await service.purchase()
            XCTFail("the purchase should have failed")
        } catch {
            // The paywall shows this error to the user.
        }

        XCTAssertFalse(service.isSubscribed)
        XCTAssertFalse(ReceiptAllowance.canAdd())
        XCTAssertFalse(service.purchaseInFlight, "the button must not stay stuck on a spinner")
    }

    // MARK: - Restore

    func testRestoreBringsBackAnExistingSubscription() async throws {
        try await service.purchase()
        // As if on a reinstall: the cache the app reads is empty.
        ReceiptAllowance.updateEntitlementCache(isSubscribed: false, expiry: nil)
        XCTAssertFalse(ReceiptAllowance.cachedIsSubscribed)

        try await service.restore()

        XCTAssertTrue(service.isSubscribed)
        XCTAssertTrue(ReceiptAllowance.cachedIsSubscribed)
    }

    func testRestoreWithNothingToRestoreGrantsNothing() async throws {
        try await service.restore()
        XCTAssertFalse(service.isSubscribed)
        XCTAssertFalse(ReceiptAllowance.isUnlimited)
    }

    // MARK: - Losing the subscription

    func testAnExpiredSubscriptionReturnsToTheFreeTier() async throws {
        useUpFreeReceipts()
        try await service.purchase()
        XCTAssertTrue(ReceiptAllowance.canAdd())

        try session.expireSubscription(productIdentifier: AppConstants.proYearlyProductID)
        try await refreshUntilNotSubscribed()

        XCTAssertFalse(service.isSubscribed)
        XCTAssertFalse(ReceiptAllowance.canAdd(), "the 25 used before subscribing still count")
    }

    func testARefundRemovesAccess() async throws {
        try await service.purchase()
        let transaction = try XCTUnwrap(session.allTransactions().last)

        try session.refundTransaction(identifier: transaction.identifier)
        try await refreshUntilNotSubscribed()

        XCTAssertFalse(service.isSubscribed)
        XCTAssertFalse(ReceiptAllowance.cachedIsSubscribed)
    }

    // MARK: - Ask to Buy

    func testAskToBuyUnlocksOnlyOnceApproved() async throws {
        session.askToBuyEnabled = true

        try await service.purchase()
        XCTAssertFalse(service.isSubscribed, "pending until a parent approves")

        let pending = try XCTUnwrap(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        try await waitUntil("approval arrives through Transaction.updates") { self.service.isSubscribed }
        XCTAssertTrue(ReceiptAllowance.cachedIsSubscribed)
    }

    // MARK: - Early users

    func testAnEarlyUserIsNeverLimitedAndNeverAskedToPay() {
        defaults.set(true, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)
        for _ in 0..<100 { ReceiptAllowance.recordUse() }

        XCTAssertTrue(ReceiptAllowance.isUnlimited)
        XCTAssertTrue(ReceiptAllowance.canAdd(1000))
        XCTAssertFalse(service.isSubscribed, "unlimited because grandfathered, not because they paid")
    }
}
