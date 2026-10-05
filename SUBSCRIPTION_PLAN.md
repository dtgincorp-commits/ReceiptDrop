# Free tier (25 receipts) + $7.99/yr subscription — design

Status: design agreed 2026-09-16. Implementation in two phases (core, then UI).

## Product decisions (settled)

| Question | Decision |
|---|---|
| Free allowance | **25 receipts, lifetime.** Does not reset. |
| Price | **$7.99/year**, auto-renewing. Unlimited receipts. |
| Existing users | **Grandfathered — free forever.** Anyone with the app before this build never sees the wall. |
| What consumes one | **Only a receipt that successfully lands in history**, plus anything parked in the queue and not yet saved (see "Closing the park hole"). Failed extractions and rejected duplicates cost nothing. |
| At the wall | **Existing receipts stay fully usable** — browse, search, edit, export, back up, restore. Only *new* ingest is blocked. |
| Scope of the gate | Every ingest path: share sheet, photo library, camera, document scan, Live Text scan, Files import, manual entry, batch. |

## Why the enforcement point is `SubmissionStore`

Every path that creates a receipt converges on `SubmissionStore.appendHistory`
(`Shared/SubmissionStore.swift:25`), reached from exactly four places, all in
`SubmissionPipeline`: `run`, `recordManualEntry`, `saveWithoutExtraction`,
`runTextOnly`. `Shared/` is compiled into both the app and the share
extension, and the store is backed by the App Group suite, so one counter is
visible to both processes. There is no ingest path that avoids it.

`mergeHistory` (Restore from backup) also writes history and **must not**
count — restoring your own backup is not new scanning.

## The counter

A dedicated monotonic `Int` in the App Group suite, `freeReceiptsUsed`,
incremented inside `appendHistory`. Deliberately *not* derived from
`loadHistory().count`:

- Deriving it would refund quota on delete — scan 25, delete 25, scan 25 more,
  forever.
- Deriving it would charge quota on Restore — a user reinstalling and
  restoring a 400-receipt backup would be instantly walled.

The counter only goes up. Deleting a receipt does not give the slot back, and
this is stated in the paywall copy so it is not a surprise.

Known and accepted limitation: delete-and-reinstall clears the App Group suite
and resets the counter. Server-side accounting is the only real fix and this
app has no server or account system. Not worth building one for $7.99/yr.

### Closing the park hole

The share extension does not save receipts; it *parks* them
(`SubmissionStore.enqueuePending` / `enqueueHeld`) and the main app drains
them later via `PendingSubmissionProcessor`. Checking only `freeReceiptsUsed`
would let a user park 100 receipts in one share-sheet session — each check
passing, because nothing has been saved yet.

So the allowance check counts pending work too:

```
used = freeReceiptsUsed + SubmissionStore.loadQueue().count
```

`PendingSubmissionProcessor` itself is **not** gated: anything already parked
was allowed at park time, and failing it later would destroy a receipt the
user was told we accepted.

## Grandfathering

Resolved once, on whichever process asks first, then frozen in the App Group
suite under `subscriptionGrandfathered`. A user is treated as existing if any
of these show a prior install:

- `submissionHistory` is non-empty
- `hasCompletedAISetup` is true
- `categories` key exists
- `lastBackupDate` exists

Edge case, accepted: someone who installed the app, never scanned anything,
never configured AI, and never opened Categories is indistinguishable from a
fresh install and gets the 25-receipt tier. That user has no receipts to lose.

Never recomputed after the first resolution — otherwise clearing history would
flip an existing user out of grandfathered status.

## Entitlement (StoreKit 2)

- Product: `com.datatechnologygroup.receipts4tax.pro.yearly`, auto-renewable,
  subscription group "Receipts4Tax Pro".
- Deployment target is iOS 16, so StoreKit 2 (`Transaction.currentEntitlements`,
  `Transaction.updates`) is available but `SubscriptionStoreView` (iOS 17+) is
  not — the paywall is hand-built.
- **The share extension never calls StoreKit.** A share sheet cannot present a
  purchase sheet, and StoreKit calls there are slow and unreliable. Instead the
  main app writes a cached snapshot (`isSubscribed`, `subscriptionExpiry`,
  `entitlementCheckedAt`) into the App Group suite on launch and on every
  `Transaction.updates` event; the extension reads only that cache.
- Cache is fail-open on staleness: if the app has not run in a long time we
  keep honouring the last-known-subscribed state rather than walling a paying
  user inside a share sheet.

## Gate points

| Where | Behaviour when out of quota |
|---|---|
| `ContentView` New Receipt menu | Present the paywall instead of the capture picker. |
| Batch submit (`BatchReceiptSubmitView`) | If batch size > remaining, show the paywall naming both numbers ("this batch has 12, you have 3 left"). Blocks the whole batch rather than silently dropping receipts. |
| Share extension `park()` | Blocked message + "Open Receipts4Tax" via the existing `receiptdrop://` deep link. No purchase UI in the extension. |
| `PendingSubmissionProcessor` | Not gated — already accepted. |

## Paywall requirements (App Review 3.1.2)

A paywall missing any of these is a rejection:

- Subscription name and what it unlocks
- Price and duration, read from `Product.displayPrice` (never hard-coded)
- Explicit "auto-renews annually until cancelled" language
- **Restore Purchases** button
- Link to Terms of Use — Apple's standard EULA is acceptable:
  `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`
- Link to the Privacy Policy — **must be the real hosted URL**, and is
  currently a placeholder constant that has to be filled before submission.

Also shown before the wall, not just at it: remaining count surfaced in
Settings ("18 of 25 free receipts used") so the limit is never a surprise.

## Manual steps (App Store Connect — cannot be done from here)

1. Paid Applications agreement signed; tax and banking complete.
2. Create subscription group "Receipts4Tax Pro".
3. Create auto-renewable subscription `com.datatechnologygroup.receipts4tax.pro.yearly`
   at $7.99/year, with localized display name, description, and a review screenshot.
4. Add the App Store promotional/review notes describing the 25-receipt free tier.
5. Fill the real Privacy Policy URL into `AppConstants`.

## Phases

**Phase 1 — core (no UI).** `ReceiptAllowance` + `SubscriptionService` in
`Shared/`, new `DefaultsKeys`, counter increment in `appendHistory`,
grandfather resolution, `Products.storekit` config wired into the scheme via
`project.yml`, unit tests.

**Phase 2 — UI.** Paywall view, gates at the four points above, Settings
subscription section, share-extension blocked state.
