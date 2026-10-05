import SwiftUI
import StoreKit

/// Why the caller reached the wall — lets the paywall say something specific
/// ("you've used all 25") instead of a generic upsell, and lets the batch
/// path name both numbers per SUBSCRIPTION_PLAN.md ("this batch has 12, you
/// have 3 left") rather than just "you're out of room".
enum PaywallReason: Identifiable {
    /// Ordinary single-receipt ingest (New Receipt menu, share extension
    /// hand-off) with no free slots left.
    case outOfFreeReceipts
    /// A batch that would push the user over the limit even though they
    /// aren't at zero yet. Carries both numbers so the message can be exact.
    case batchExceedsRemaining(batchCount: Int, remaining: Int)
    /// Opened from Settings before the user has hit the wall at all — no
    /// specific trigger, just browsing.
    case general

    /// Lets call sites present this with `.fullScreenCover(item:)`/`.sheet(item:)`
    /// without a separate wrapper type. Not the associated values themselves
    /// (batch counts can legitimately repeat across presentations) — just
    /// enough to distinguish the cases for SwiftUI's identity tracking.
    var id: String {
        switch self {
        case .outOfFreeReceipts: return "outOfFreeReceipts"
        case .batchExceedsRemaining(let batchCount, let remaining): return "batch-\(batchCount)-\(remaining)"
        case .general: return "general"
        }
    }

    var headline: String {
        switch self {
        case .outOfFreeReceipts:
            return "You've used all 25 free receipts"
        case .batchExceedsRemaining(let batchCount, let remaining):
            return "This batch has \(batchCount) receipts, but you have \(remaining) free \(remaining == 1 ? "one" : "ones") left"
        case .general:
            return "Go unlimited"
        }
    }

    var subheadline: String {
        switch self {
        case .outOfFreeReceipts:
            return "Every receipt you've filed with Receipts4Tax is still here — browse, search, edit, and export it anytime. Adding a new one needs Pro."
        case .batchExceedsRemaining:
            return "Subscribe to add the whole batch at once instead of trimming it down."
        case .general:
            return "Unlimited receipts, no counting, no wall."
        }
    }
}

/// Hand-built paywall for the $7.99/year "unlimited receipts" subscription —
/// see SUBSCRIPTION_PLAN.md. Hand-built rather than `SubscriptionStoreView`
/// because the deployment target is iOS 16 and that API is iOS 17+.
///
/// Every element on this screen exists to satisfy a specific clause of App
/// Review guideline 3.1.2 — see the inline comments below for which one.
/// Deleting any single piece here (not just the whole screen) is a
/// resubmission risk, not a style choice.
struct PaywallView: View {
    let reason: PaywallReason
    /// Called after a successful purchase (or restore that finds an active
    /// entitlement) so the presenter can dismiss and let the caller retry
    /// whatever ingest action brought the user here. Also called from the
    /// toolbar's Cancel/X — the caller distinguishes "bought it" from
    /// "backed out" by re-checking `ReceiptAllowance.canAdd` itself, which is
    /// simpler than threading a second closure through every gate site.
    let onFinish: () -> Void

    @ObservedObject private var service = SubscriptionService.shared
    @State private var purchaseError: String?
    @State private var restoreInFlight = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    priceCard

                    benefitsList

                    // Auto-renewal disclosure — App Review 3.1.2 requires this
                    // in terms explicit enough that a user isn't surprised by
                    // a renewal charge. Kept as its own block (not folded into
                    // `benefitsList`) so it reads as a disclosure, not a perk.
                    Text("Renews automatically every year at the price shown above until you cancel. Cancel anytime in Settings › Apple ID › Subscriptions — no need to contact us.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // Honesty about the counter being monotonic, per the
                    // plan: better the user hears this here than discovers it
                    // after deleting receipts expecting slots back.
                    Text("Note: deleting a receipt doesn't return a free slot — the 25-receipt count only ever goes up. Pro removes the limit entirely rather than resetting it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    if let purchaseError {
                        Label(purchaseError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    purchaseButton

                    restoreButton

                    legalLinks

                    #if DEBUG
                    // Loud, developer-only tripwire: `privacyPolicyURL` is
                    // still the empty-string placeholder from AppConstants.
                    // Shipping this build to App Review would be a guideline
                    // 3.1.2 rejection (no Privacy Policy link) that would only
                    // be discovered days later in review notes. Surfacing it
                    // here, in the exact screen that needs the link, means
                    // whoever runs a DEBUG build before submission cannot
                    // miss it. Compiled out of RELEASE, so it never reaches a
                    // real user or App Review's own build.
                    if AppConstants.privacyPolicyURL.isEmpty {
                        Text("DEBUG: privacyPolicyURL is empty — fill it in AppConstants before submitting. See the TODO(appstore) there.")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 24)
                    }
                    #endif
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Receipts4Tax Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", action: onFinish)
                }
            }
            .task {
                // The paywall can be the very first thing that needs the
                // product (e.g. deep into a cold-launch ingest gate before
                // `SubscriptionService.start()`'s own load has finished), so
                // it re-requests rather than assuming the app-launch load
                // already completed.
                if service.product == nil {
                    service.start()
                }
            }
            .onChange(of: service.isSubscribed) { subscribed in
                if subscribed { onFinish() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "infinity.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.actionBlue)
                .accessibilityHidden(true)

            Text(reason.headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(reason.subheadline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    /// Price and duration, read live from `Product.displayPrice` — never
    /// hard-coded, per App Review 3.1.2 and `SubscriptionService`'s own
    /// comment. If the product hasn't loaded (offline, misconfigured product
    /// ID, App Store Connect not yet propagated), shows a plain "unavailable"
    /// state instead of a fabricated or blank price — a paywall that shows
    /// the wrong price is worse than one that honestly can't show one yet.
    @ViewBuilder
    private var priceCard: some View {
        VStack(spacing: 6) {
            if let product = service.product {
                Text(product.displayPrice)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("per year")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Loading price…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        // A translucent tint rather than the fixed `Theme.skyBlueLight`: that
        // stays pale in dark mode while the text above turns white, which
        // left the price nearly invisible and "per year" not at all.
        .background(Theme.skyBlue.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefitRow(icon: "infinity", text: "Unlimited receipts — no counting, ever again")
            benefitRow(icon: "checkmark.shield.fill", text: "Everything you've already filed stays exactly as it is")
            benefitRow(icon: "square.and.arrow.up", text: "All export and backup features, unchanged")
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.actionBlue)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
    }

    private var purchaseButton: some View {
        Button {
            purchase()
        } label: {
            HStack {
                if service.purchaseInFlight {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Subscribe")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.actionBlue)
        .disabled(service.product == nil || service.purchaseInFlight)
        .padding(.horizontal, 32)
    }

    /// App Review 3.1.2 requires a working Restore Purchases affordance on
    /// every paywall — a user who reinstalls, or bought on another device
    /// signed into the same Apple ID, has no other way back to their
    /// entitlement from here.
    private var restoreButton: some View {
        Button {
            restore()
        } label: {
            if restoreInFlight {
                ProgressView()
            } else {
                Text("Restore Purchases")
                    .font(.subheadline)
            }
        }
        .disabled(restoreInFlight)
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Link("Terms of Use", destination: URL(string: AppConstants.termsOfUseURL)!)

            // Guarded rather than force-unwrapped like Terms above: should
            // `privacyPolicyURL` ever be emptied again, a `Link` built from
            // it would crash or render a dead tap target. Rendering nothing
            // is the safe failure, and the DEBUG banner above makes the gap
            // impossible for a developer to miss.
            if let privacyURL = URL(string: AppConstants.privacyPolicyURL), !AppConstants.privacyPolicyURL.isEmpty {
                Link("Privacy Policy", destination: privacyURL)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func purchase() {
        purchaseError = nil
        Task {
            do {
                try await service.purchase()
                // `.userCancelled` and `.pending` both return normally from
                // `SubscriptionService.purchase()` (see its own comment) —
                // neither is a failure, so neither should produce an alert
                // here. The only way to tell "cancelled" apart from "bought
                // it" from this side is `isSubscribed`, checked below.
                if !service.isSubscribed {
                    // Not subscribed after a non-throwing purchase() call is
                    // either a user-initiated cancel (say nothing — the user
                    // meant it) or a `.pending` approval (Ask to Buy and
                    // similar) that will resolve later via
                    // `Transaction.updates`. Distinguish by asking StoreKit
                    // whether anything is still outstanding is not available
                    // here without deeper plumbing, so the pending case gets
                    // a gentle, non-alarming note rather than silence — a
                    // silent "nothing happened" after a real purchase attempt
                    // reads as broken, whereas this note is harmless if it
                    // was actually just a cancel.
                    restoreMessage = "If this needs approval (like Ask to Buy), it'll unlock automatically once approved."
                }
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    private func restore() {
        restoreInFlight = true
        restoreMessage = nil
        purchaseError = nil
        Task {
            defer { restoreInFlight = false }
            do {
                try await service.restore()
                if !service.isSubscribed {
                    restoreMessage = "No active subscription found for this Apple ID."
                }
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }
}
