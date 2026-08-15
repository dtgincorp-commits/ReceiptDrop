# Multi-Receipt Share Extension — Implementation Plan

Lets the user select several photos in the iOS share sheet and send them all
to ReceiptDrop at once. Today ReceiptDrop silently disappears from the share
sheet whenever more than one photo is selected.

---

## Why

`project.yml:83-85` declares:

```yaml
NSExtensionActivationRule:
  NSExtensionActivationSupportsImageWithMaxCount: 1
  NSExtensionActivationSupportsFileWithMaxCount: 1
```

iOS uses `NSExtensionActivationRule` to decide which apps to offer for a given
selection. `MaxCount: 1` means the extension self-disqualifies for any
multi-select, so ReceiptDrop is filtered out before the sheet renders — which
is why it vanishes with no error rather than showing a message.

This was a correct constraint when written: `ShareSheetView.loadAttachment()`
(`ShareExtension/ShareSheetView.swift:44-68`) picks a single provider with
`providers.first(where:)` and ignores the rest. Raising `MaxCount` alone would
let iOS offer the extension for 5 photos and then silently import only one.

## What already exists — do not rebuild any of this

Most of the feature is already in the codebase, built for the main app's
"pick several from library" flow:

- **`ReceiptDrop/BatchReceiptSubmitView.swift`** — takes `[SharedAttachment]`,
  shows "N photos selected", one category picker for the whole batch, a
  "Submit All" button. Verified to have **no main-app-only dependencies**.
- **`Shared/BatchSubmissionRunner.swift`** — loops each attachment through
  `SubmissionPipeline` independently, so one bad photo doesn't block the rest.
  Already in `Shared/`.
- **`Shared/CategoryStore.swift`**, `SharedAttachment` (in
  `Shared/ReceiptSubmitView.swift`), `SubmissionPipeline`, `SubmissionStore`,
  `LocalReceiptStore` — all already in `Shared/`.
- **The App Group spool** (`Shared/LocalReceiptStore.swift:9-14`) — the
  extension can't write to the app's Documents directory, so it writes to the
  App Group spool and the main app drains it on activation. This is the
  existing, working extension→app handoff and the batch path should use it.

`ShareExtension`'s sources are `ShareExtension` + `Shared` (`project.yml:64-66`),
so anything already in `Shared/` is available to the extension today.

---

## The critical constraint — extension process lifetime

**This is the part most likely to be gotten wrong.**

`BatchReceiptSubmitView.submitAll()` (`ReceiptDrop/BatchReceiptSubmitView.swift:87-94`)
starts `BatchSubmissionRunner.submit(...)` on a **detached task**, waits 700ms,
then calls `onComplete()`. In the main app that is safe — the app stays alive
and the detached task runs to completion.

In the **share extension** it is not. `onComplete()` reaches
`extensionContext?.completeRequest(returningItems: nil)`
(`ShareExtension/ShareViewController.swift:16-18`), and iOS terminates the
extension process at that point. The detached batch would be killed after
roughly 700ms and most receipts would be lost, with no error shown.

So `BatchReceiptSubmitView` **cannot be reused as-is in the extension**. Its
fire-and-forget submission model has to be replaced for the extension path.

### Decision: durable-first, extract later

In the extension, do **not** run `SubmissionPipeline` (and therefore the AI
round-trip) for the batch. Instead:

1. Write each photo to the App Group spool immediately via
   `LocalReceiptStore.save(data:category:kind:)` — fast, local, no network,
   and already downscales to 1568px.
2. Record each as a pending item the main app will process.
3. `completeRequest` right away.
4. The main app picks the pending items up on next activation and runs them
   through `SubmissionPipeline` exactly as it does for a queued retry.

Rationale: N receipts × one Claude round-trip each is far too long to hold a
share sheet open, and iOS kills extensions that overrun. Writing files first
means nothing is ever lost even if the process is terminated a moment later.

**Keep the single-receipt path exactly as it is.** One receipt through
`ReceiptSubmitView` with the live pipeline works today and gives immediate
extraction feedback; there is no reason to change it.

### Note on `SubmissionStore.enqueue`

The existing signature (`Shared/BatchSubmissionRunner.swift:35-36`) is:

```swift
SubmissionStore.enqueue(data:category:kind:error:)
```

It was built for submissions that **already failed**, hence the required
`error:` string. Batch items from the extension have not been attempted yet,
so reusing it verbatim would mislabel them as failures in the Retry Queue UI.

Pick one and be deliberate:
- **Preferred:** add a distinct "pending" state (or make `error:` optional) so
  the queue can show "waiting to process" separately from "failed". Check how
  `QueueEntryDetailView` renders entries before choosing.
- **Acceptable shortcut:** reuse `enqueue` with a neutral message, accepting
  that these show up alongside genuine failures.

Do not silently pass an empty string and leave the UI implying failure.

---

## Steps

1. **`project.yml:84-85`** — raise both counts. Use a modest cap (**5–10**, not
   unlimited) — see Memory below. Then run `./generate.sh`.
2. **`git mv ReceiptDrop/BatchReceiptSubmitView.swift Shared/`** — makes it
   compile into the extension. No code changes required to the file itself
   beyond the submission-model change in step 4.
3. **`ShareExtension/ShareSheetView.swift` — `loadAttachment()`** — replace the
   single `providers.first(where:)` lookup with logic that loads *every*
   provider and collects `[SharedAttachment]`. `loadDataRepresentation` is
   callback-based, so the N loads must be coordinated (async/await with a
   `TaskGroup`, or a `DispatchGroup`) and state flipped only once all have
   settled. Preserve the existing behaviour of accepting both
   `UTType.image` and `UTType.pdf`, and of reporting a load error when nothing
   usable is found. A provider that fails to load should not abort the whole
   batch — skip it and report how many were skipped.
4. **Extension batch submission** — implement the durable-first path described
   above. This may be a new small view/handler in `ShareExtension/` rather than
   modifying `BatchReceiptSubmitView` directly, so the main app's existing
   fire-and-forget behaviour is left untouched.
5. **`ShareExtension/ShareSheetView.swift` — `body`** — route on count:
   exactly 1 → `ReceiptSubmitView` (unchanged), more than 1 → the batch view.
6. **`./generate.sh`** and rebuild.

## Memory

Share extensions run under a substantially tighter memory budget than the host
app. Holding several full-resolution camera photos as `Data` plus decoded
`UIImage` thumbnails simultaneously is the most likely crash source here.

- Do **not** generate thumbnails for the batch path —
  `BatchReceiptSubmitView` only displays a count, and
  `SharedAttachment.thumbnail` is already optional (`UIImage?`), so pass `nil`.
- Write each photo to the spool and release its `Data` as soon as possible
  rather than holding all N in memory at once.

## Two-tier limit: OS ceiling vs. friendly limit — do not use one number for both

`NSExtensionActivationRule`'s `MaxCount` is enforced by iOS **before the
extension process launches**. If it's set to the same number as the intended
"please keep batches reasonable" guidance (5), then selecting 6+ photos makes
ReceiptDrop silently vanish from the share sheet — the exact bug this whole
plan exists to fix, just moved from 1 to 5. The extension's own code, and any
warning message it could show, never runs in that case, because iOS filters
the app out of the sheet itself.

So use two different numbers:

- **`project.yml:84-85` `MaxCount`** — set generously higher than the intended
  guidance, e.g. **20**. This is purely about keeping ReceiptDrop visible in
  the share sheet for a realistic range of selections; it is not the number
  shown to the user anywhere.
- **In-extension soft limit (5)** — enforced in the batch view/handler from
  step 4, *after* the extension has actually launched and can render UI. When
  `extensionItems.count` (or the loaded `[SharedAttachment]` count) exceeds 5,
  show a clear message — e.g. "You selected N receipts — please pick 5 or
  fewer at a time" — with Cancel, rather than attempting the batch.

This does not eliminate the silent-disappearance case entirely — someone
selecting more than the OS ceiling (20) still won't see ReceiptDrop offered at
all, with no explanation, same as today. It converts the realistic case
(someone modestly over the friendly limit) from silent failure into a real
in-app message, which is the best that's achievable given the OS mechanism.

## Deliberately out of scope

- **The single-receipt flow** — unchanged in both behaviour and code path.
- **The main app's existing batch flow** (`NewReceiptView.swift:41`) — keeps
  its current fire-and-forget `BatchSubmissionRunner` behaviour, which is
  correct there.
- **Per-receipt category selection** — one category for the whole batch,
  matching the existing `BatchReceiptSubmitView` design.
- **Duplicate detection changes** — each queued receipt still runs through
  `SubmissionPipeline`, which already applies the duplicate checks.

---

## Related, separate bug — in-app "New Receipt" → library picker has no limit at all

Found while scoping this plan; not the same code path as the share extension,
but the same class of problem and worth fixing alongside it.

`ReceiptDrop/NewReceiptView.swift:102-103`:

```swift
.photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
              maxSelectionCount: 0, matching: .images)
```

`maxSelectionCount: 0` is `PhotosPicker`'s documented value for **no limit**.
This is already-shipped code, not a share-sheet quirk: a user picking receipts
from their library in-app today can select any number of photos — 200, say —
and every one of them is loaded (`onChange(of: photoPickerItems)`,
`NewReceiptView.swift:104-121`) and handed to `BatchReceiptSubmitView` →
`BatchSubmissionRunner`, which fires one AI extraction call per photo with
**no confirmation or warning shown at any point**.

This is arguably worse than the share-extension `MaxCount` issue: it doesn't
fail loudly or disappear — it silently accepts an unbounded batch and grinds
through it, with the user having no idea how many API calls just got queued
until they come back to a very long-running batch (or a large bill).

### Fix — same two-tier idea, applied where it actually can be: entirely in-app

Unlike the share extension, this path has no OS-level ceiling to work around —
`PhotosPicker` is presented by the main app, which is always running and can
show UI. So this doesn't need two tiers; one guarded confirmation step is enough:

1. Set `maxSelectionCount` to a real number (e.g. **20**) instead of `0`, so
   `PhotosPicker`'s own UI stops the user from over-selecting in the first
   place, with its own native "N of 20 selected" affordance.
2. In the `onChange(of: photoPickerItems)` handler
   (`NewReceiptView.swift:104-121`), after `loaded` is built: if
   `loaded.count > 5` (matching the share extension's friendly limit for
   consistency), show a confirmation alert — "You selected N receipts — this
   will make N AI requests. Continue?" — before setting `batchAttachments`.
   Only proceed into `BatchReceiptSubmitView` on confirmation; on cancel,
   `dismiss()` as the existing "nothing loaded" path already does.
3. `BatchReceiptSubmitView` itself needs no changes — it already just takes
   whatever `[SharedAttachment]` it's given.

### Verification (this section)

- Manual: select 3 photos in-app → no confirmation, proceeds directly
  (unchanged from today).
- Manual: select 8 photos in-app → confirmation alert shown with correct
  count; Cancel returns to the picker/dismisses cleanly; Continue proceeds to
  `BatchReceiptSubmitView` as today.
- Manual: attempt to select more than 20 in the system picker → picker's own
  UI prevents it (no app code needed for this part).

---

## Verification

- Full test suite green.
- Manual: share 1 photo → unchanged live-extraction flow.
- Manual: share 3 photos → all 3 land, appear after opening the app.
- Manual: share a mix of image + PDF.
- Manual: kill the extension immediately after "Submit All" (swipe away the
  sheet) and confirm the receipts still arrive — this is the specific failure
  the durable-first design exists to prevent.
