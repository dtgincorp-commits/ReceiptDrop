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

## The plan

### The staging tray — and why it is NOT the Pending screen

The obvious idea is "let false positives through, they can sit in Pending until
the user deletes them." That does not work, and the reason matters.

`QueueEntry` is a **failed submission**: it carries an `error` string, holds a
file under `PendingReceipts`, and `PendingSubmissionProcessor` retries it
automatically. It is a retry queue, not a waiting room. A false positive
pushed through the normal pipeline would:

1. spend a real AI extraction call **on the user's own API key** — at roughly
   1–3¢ each, two hundred false positives is real money spent reading
   photographs of somebody's dog;
2. come back with garbage vendor/amount/date;
3. be **saved as a genuine receipt** — file written, CSV row appended, history
   entry created — landing in the user's tax records rather than in a holding
   pen.

So the tray has to be a **new surface that is not the pipeline**:

- "12 possible receipts found", thumbnails, each with a score and a one-line
  reason ("total + tax + currency amounts detected").
- Nothing extracted, nothing saved, nothing spent, until the user taps.
- Tapping the real ones submits them as a normal batch through
  `SubmissionPipeline` — reusing `BatchSubmissionRunner`.
- Dismissed asset IDs are remembered so nothing reappears.
- Untouched suggestions expire after ~30 days so the tray cannot grow forever.

This is what makes false positives genuinely cheap, which is the property the
whole feature depends on.

### When it runs

Three triggers. No background magic.

1. **On app foreground** — alongside `AutoBackupService.runIfDueOnForeground()`
   and `ReceiptHashBackfillService.runOnForeground()` in `ReceiptDropApp`.
   Scans only assets added since the last run: a handful of photos, tens of
   milliseconds, invisible.
2. **An explicit historical sweep**, user-initiated, with a progress bar and a
   cancel. Never automatic.
3. Later, optionally, a `BGProcessingTask` so the historical sweep can run
   overnight on power. **Not for v1** — the system decides when these run and
   the scheduling is too unpredictable to design a first version around.

### Sweep scope — user's choice, one year by default

Default to **the last 12 months**, because that is the window that matters for
a tax year and it bounds the cost. But offer the full range as an explicit
option; someone starting the app with four years of receipts on their phone
should be able to get at them:

- Last 12 months (default)
- Last 2 years
- Everything

Show the asset count and an estimated duration before starting, so "Everything"
is a decision with a number attached rather than a shrug. The scan is
resumable and remembers its position, so a cancelled or interrupted sweep does
not start over.

### Resource cost

Planning figure: ~5,000 photos for an average year.

Vision fast text recognition on a **thumbnail** runs roughly 30–80ms per image
on recent hardware. So a one-year sweep is on the order of **8–12 minutes of
work**, chunked into batches — call it 3–6% of battery and a warm phone, once.
"Everything" scales linearly: four years is roughly four times that, which is
exactly why it must be opt-in with the number shown.

After the sweep, incremental scanning is a few photos a day. Effectively free.

**The detail that decides whether any of this is viable:** with iCloud Photos
and "Optimize iPhone Storage" enabled, full-resolution images are not on the
device. Request small thumbnails with `isNetworkAccessAllowed = false` —
thumbnails are always local. Get this wrong and the sweep triggers thousands of
iCloud downloads: slow, and expensive on cellular.

Batch in chunks (a few hundred assets), yield between chunks, and stop early on
low battery or thermal pressure.

### Phasing

**Phase 0 — spike, ~300 lines.** A hidden developer screen that runs the
classifier over a folder of images and prints scores. No permission, no tray,
no import path. Feed it the 16 fixtures in `test-receipts/` plus ~30 ordinary
camera-roll photos and read the confusion matrix. This answers the only
question that matters — *is detection good enough to justify the permission?* —
for a fraction of the cost of finding out later.

**Negatives have to be supplied.** `test-receipts/` is all positives, so
precision is currently unmeasurable. Photos of people, pets, menus,
whiteboards, business cards and non-receipt screenshots are what the
classifier will actually be wrong about.

**Phase 1 — the real thing**, only if Phase 0 looks good. Permission handling
(including the "Limited access" case, which would otherwise cripple it
silently), the seen-asset ledger, the suggestions tray, the sweep UI with scope
selection, and the foreground trigger. Roughly 2–3 delegated sessions,
1,200–1,500 lines.

**Phase 2 — background sweep** via `BGProcessingTask`, if the explicit sweep
proves too slow to sit through.

### Dedupe, for free

Imported suggestions must be checked against `HistoryEntry.fileHash` before
being offered — a photo the user already filed should never appear in the tray.
The content-fingerprint work (`ReceiptFileHash`, commit `e1d36e2`) already
provides this; the tray just has to use it.

## Sources

- Ramp — Auto-Match Receipts from Your Camera Roll: <https://support.ramp.com/auto-match-receipts-from-your-camera-roll>
- Ramp — Corporate Cards: <https://ramp.com/corporate-cards>
- Ramp: <https://ramp.com/>

---

## Unrelated item parked for the same build

**Say where backups live.** Nothing in the UI explains the asymmetry that
`LocalReceiptStore.excludeReceiptsFromBackup()` deliberately creates: receipt
images and CSVs are marked `isExcludedFromBackup = true` and stay out of
iCloud, while the backup **zips** in `Documents/Backups` are not excluded and
therefore ride along in the iOS device backup automatically. That is the
recovery path for a lost phone, and the user has no way to know it exists.

A per-backup "location" column does not work — every backup is in the same
place, so the column would always read the same. One line in the Backup
section is the right shape:

> Backups are saved on this iPhone and included in your iCloud device backup,
> if that's turned on. Receipt images themselves are deliberately kept out of
> iCloud.

Limit worth respecting in the wording: there is no API to detect whether iCloud
Backup is actually enabled, so the copy must say "if that's turned on" rather
than claiming it is handled.

**Deliberately NOT adding a setting to turn the exclusion off.** That was
already decided in `8db1ffb` and the reasoning still holds: the zips already
contain the receipts and already reach iCloud, so a toggle would only offer to
put every image there a second time — more storage, a weaker privacy claim, and
another entry to declare in App Privacy, for no recovery benefit.
