# Auto-import from the photo library — research notes

Parked until 1.0 (3) is through external testing. Nothing here is built.

**The problem, as reported:** a user photographs his receipts and then never
adds them to the app. The capture happens; the filing doesn't.

---

## The core constraint

There is no third option. Either **the user does something** (cheap, precise,
no classification) or **the app scans his library** (habit-free, but needs a
photo permission and has to guess what a receipt looks like).

An album or a Favorites flag looked like a middle path and isn't: if he can
remember to add a photo to a "Receipts" album, he can just as easily
multi-select and share into the app — which already works today (see below).
The album adds a step and buys nothing. It only helps if the flagging happens
*at capture time*, and that is still a habit.

## What already exists, and should be ruled out first

The Share Extension already handles **multi-photo batches**:
`ExtensionBatchSubmitView` + `BatchSubmissionRunner`, which submits in the
background rather than holding the user on a progress screen. He can select
twenty receipts in Photos → Share → Receipts4Tax → done.

So the feature may already exist and simply not be known. **Test that before
building anything.**

Cheapest experiment of all: a weekly local notification — "You haven't added
any receipts in 7 days." No permissions, no scanning, no classification,
roughly twenty lines. If the problem is forgetfulness rather than friction,
that is the entire fix.

---

## Prior art: Ramp

Ramp is the only app found doing genuine background camera-roll detection.
Everything else in the category (Expensify, QuickBooks, ReceiptGenie, the
various "AI Receipt Scanner" apps) offers *manual import* — a picker the user
opens, which is not this.

What Ramp does, from their support documentation:

- All matching happens **on device**; photos and camera-roll data are not sent
  to their servers during matching.
- **Nothing uploads until the user confirms.** No receipt is shared until the
  match is reviewed and approved.
- A single opt-in toggle, "Find receipts in my photo library," reversible at
  any time.
- Uses **Apple Intelligence** to judge whether a photo contains the expected
  amount, date and merchant.
- Requires **iPhone 15 Pro or later on iOS 26+** — the same Apple Intelligence
  hardware floor that makes on-device-only extraction unviable for us at an
  iOS 16 deployment target.

### The part that cannot be copied

**Ramp is a corporate card issuer, not a receipt app.** Businesses sign up,
Ramp issues cards to employees, and the expense tooling manages spend on
Ramp's own cards. So Ramp already holds the transaction: $47.20, 2:14pm, this
merchant.

That turns an open-ended classification problem into a lookup. Ramp never asks
"is this a receipt?" across ten thousand photos — it asks "does this photo
show $47.20 from this merchant?" of the few photos taken just after 2:14pm.
Cheap and accurate, because the answer is already known.

We have no transaction feed. Getting one means bank aggregation (Plaid or
similar), which means accounts, a server, and stored credentials — demolishing
the architecture the product is built on ("no account, no server, we never see
your receipts"). Not a feature to bolt on; a different company.

Their problem is also different in kind: Ramp's users are employees who *must*
produce a receipt to justify a charge that already exists. Ramp solves
compliance. We solve capture.

**Takeaway:** copy the *shape* — on-device only, one opt-in toggle, nothing
leaves until the user confirms — and note that Apple approved it, so the
pattern is shippable. The matching technique is not available to us.

---

## If we build it

**Scan forward only.** Record a timestamp when the feature is enabled and only
examine photos taken after it. A handful a day is milliseconds. The expensive
part was never the scanning, it was the historical sweep of thousands of
existing photos — so don't do one automatically. Offer "Scan my last 90 days"
as a separate, explicit button with a visible progress bar.

Rough cost if a sweep is run: Vision fast text recognition on a *thumbnail*
runs on the order of 30–80ms per image on recent hardware, so a 5,000-photo
library is a few minutes of solid compute, with the heat and battery drain
that implies. Once. Incremental scanning afterwards is trivial.

**Detect locally, then ask. Never auto-submit.** Anything plausible goes into a
"Found 14 possible receipts" tray with thumbnails; the user taps the real ones
and those enter the normal pipeline. Auto-submitting would spend the user's own
API credits without asking and would manufacture tax records nobody confirmed —
precisely the failure `b711974` and `3220a4f` exist to prevent.

**Classification signal we already own:** `ReceiptAmountDetector`
(currency-shaped text), `ReceiptDateDetector`, plus keywords (TOTAL, SUBTOTAL,
TAX, VISA). `PHAsset.mediaSubtypes.contains(.photoScreenshot)` is another
strong hint — several real receipts here are screenshots. Expect false
positives from menus, business cards, whiteboards and bank statements.

**Worth checking before designing anything:** iOS 18's Photos app auto-groups
receipts under its Utilities section. Whether PhotoKit exposes that collection
through a public API is unknown — if it does, it beats anything we would build.
Ten minutes in the PhotoKit documentation answers it.

### Costs to accept before starting

- **A photo-library permission the app does not currently ask for.** Today
  `PhotosPicker` runs out of process, which is why there is no
  `NSPhotoLibraryUsageDescription` in the plist at all. Full library access is
  a real step back from that posture, and "Limited" access — which users can
  choose — would silently cripple the feature.
- A privacy-policy revision and an App Review conversation.
- Background execution is not reliable: `BGProcessingTask` runs when the system
  decides, typically overnight on power, sometimes not for days.
  `PHPhotoLibraryChangeObserver` only fires while the app is running. Foreground
  scanning on launch is the dependable path.

---

## Open question worth answering first

This is currently **n = 1**. Before spending a permission, a policy change and
a review conversation on one person's habit, find out whether he is typical.

The app has no analytics by design, so this cannot be measured — it has to be
asked. Put the question in TestFlight's "What to Test" ("Do you photograph
receipts and add them later? What stops you?"), or email the external group
once it exists.

## Sources

- Ramp — Auto-Match Receipts from Your Camera Roll: <https://support.ramp.com/auto-match-receipts-from-your-camera-roll>
- Ramp — Corporate Cards: <https://ramp.com/corporate-cards>
- Ramp: <https://ramp.com/>
