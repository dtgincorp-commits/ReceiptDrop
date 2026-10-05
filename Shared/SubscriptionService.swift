import Foundation
import StoreKit

/// Drives the one purchasable product — $7.99/year, unlimited receipts — via
/// StoreKit 2. Deployment target is iOS 16, so `Transaction.currentEntitlements`
/// and `Transaction.updates` are available but `SubscriptionStoreView` (iOS
/// 17+) is not; the paywall (Phase 2) is hand-built against this class.
///
/// Lives in `Shared/` alongside `ReceiptAllowance` because both targets
/// import the same module, but this type is only ever *instantiated* by the
/// main app. The StoreKit framework itself links and compiles fine into an
/// app extension — nothing here fails to build in `ShareExtension` — but the
/// share extension deliberately never calls into it: a share sheet has no
/// reliable way to present a purchase confirmation, and per
/// SUBSCRIPTION_PLAN.md the extension only ever reads the cached snapshot
/// this class writes (`ReceiptAllowance.cachedIsSubscribed`/`cachedExpiry`).
/// `@MainActor` also makes it awkward to touch from the extension's own
/// (non-UI, background-friendly) code paths, which is a feature, not a gap.
@MainActor
final class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    @Published private(set) var product: Product?
    @Published private(set) var isSubscribed: Bool = false
    @Published private(set) var purchaseInFlight: Bool = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// Loads the product, refreshes the current entitlement, and starts
    /// listening for `Transaction.updates` (renewals, revocations, and
    /// purchases completed outside this process, e.g. Ask to Buy approval).
    /// Idempotent — safe to call once at app launch and it will not spawn a
    /// second listener task if called again.
    func start() {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    await self?.handle(update)
                }
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlements()
        }
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [AppConstants.proYearlyProductID])
            product = products.first
        } catch {
            // Network failure or misconfigured product ID — leave `product`
            // nil. The paywall (Phase 2) is responsible for showing a retry
            // affordance rather than a hard-coded price when this happens;
            // nothing here should ever fabricate a price or duration.
            product = nil
        }
    }

    /// Re-derives `isSubscribed` from `Transaction.currentEntitlements` and
    /// writes the result through to `ReceiptAllowance`'s cache — the only
    /// path the share extension trusts. Called from `start()`, after every
    /// `Transaction.updates` event, and after `restore()`.
    func refreshEntitlements() async {
        var subscribed = false
        var expiry: Date?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == AppConstants.proYearlyProductID,
                  transaction.revocationDate == nil
            else { continue }

            // `expirationDate` is nil for non-subscriptions; this product is
            // always a subscription, but the optional is handled rather than
            // force-unwrapped in case StoreKit ever hands back something
            // unexpected here.
            if let expirationDate = transaction.expirationDate, expirationDate > Date() {
                subscribed = true
                expiry = expirationDate
            }
        }

        isSubscribed = subscribed
        ReceiptAllowance.updateEntitlementCache(isSubscribed: subscribed, expiry: expiry)
    }

    /// Buys the yearly subscription. Throws on an actual purchase-flow
    /// failure; a user-initiated cancel and a pending (e.g. Ask to Buy)
    /// purchase are both treated as "not an error" since neither is a
    /// failure the caller should surface as one.
    func purchase() async throws {
        guard let product else {
            throw SubscriptionError.productNotLoaded
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                await refreshEntitlements()
            case .unverified:
                // StoreKit could not verify the JWS signature (jailbroken
                // device, tampered receipt, etc.). We deliberately do NOT
                // finish the transaction or grant entitlement here — an
                // unverified transaction is treated as if the purchase
                // hadn't happened, which is the conservative choice for a
                // paid feature. `Transaction.updates` will keep re-delivering
                // it, so a legitimate transaction that failed verification
                // for a transient reason isn't silently lost, only withheld.
                break
            }
        case .userCancelled:
            break
        case .pending:
            // Ask to Buy or similar — StoreKit will resolve this later via
            // Transaction.updates; nothing to finish now.
            break
        @unknown default:
            break
        }
    }

    /// Re-syncs purchases from the App Store (the Restore Purchases button
    /// App Review 3.1.2 requires on every paywall) and re-derives entitlement
    /// from the result.
    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        switch update {
        case .verified(let transaction):
            await transaction.finish()
        case .unverified:
            // Same reasoning as in `purchase()` — do not finish or trust an
            // unverified transaction.
            break
        }
        await refreshEntitlements()
    }
}

enum SubscriptionError: LocalizedError {
    case productNotLoaded

    var errorDescription: String? {
        switch self {
        case .productNotLoaded:
            return "Couldn't load subscription details. Check your connection and try again."
        }
    }
}
