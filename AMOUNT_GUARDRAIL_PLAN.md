# Catch invented amounts, and tell the user to re-shoot

## In plain English

Confirmed real case: a Naan and Kabob receipt where the printed lines were

```
PRE-TIP AMT     $66.23
TIP             ______   (blank)
TOTAL AMOUNT    ______   (blank)
```

The app saved **$142.51** — a number that appears nowhere on that receipt.

This isn't a misread. It's fabrication: the model is told to find "the GRAND
TOTAL at the very bottom… NEVER an individual line-item price," that total is
blank, the one visible number is forbidden by that instruction, and so it
produced something *shaped like* a restaurant total. Note it was explicitly
permitted to return an empty string and fabricated anyway — the same behavior
as the date bug, where it returned today's date rather than nothing. Three
rounds of prompt rewording did not fix that one; a deterministic cross-check
did.

So: same fix, applied to amounts. **If the amount the model reports doesn't
appear anywhere in the receipt's text, it was invented.** No AI needed to
check that — just look for the number in the OCR output.

Plus two things the user asked for directly:
- When the amount can't be trusted, **say so and tell them to re-shoot** —
  ideally with Scan Receipt, which produces a far better image than Take Photo.
- Rename **"Scan Documents" → "Scan Receipt"**.

## One deliberate difference from the date guardrail

The date guardrail *auto-corrects* when the receipt shows exactly one date.
**Do not do that for amounts.** A receipt has many numbers — line items,
subtotal, tax, tip, pre-tip, card fragments — and picking the wrong one writes
a confidently wrong figure into a tax record. Dates are usually unambiguous;
amounts are not.

**Amounts: flag and ask the user. Never auto-correct.**

---

## Step 1 — Extract every amount printed on the receipt

**New file:** `Shared/ReceiptAmountDetector.swift`

```swift
enum ReceiptAmountDetector {
    /// Every currency-looking amount in the text, normalized to 2dp strings.
    static func amounts(in text: String) -> Set<String>
}
```

Notes:
- Regex over the whole text for currency figures — optional `$`, digits with
  optional thousands separators, optional 2-decimal tail. `BillTotalsParser
  .trailingAmount` (`ReceiptModels.swift:1044`) has a working pattern to
  borrow, but it is anchored to end-of-line (`\s*$`) because it pulls the
  amount off a labeled line. This one must match **anywhere** in the text, so
  drop the anchor.
- Normalize with the same `String(format: "%.2f", value)` trick
  `DuplicateDetectionService.normalizedAmountKey` uses, so `245.6` and
  `245.60` compare equal. Strip commas before `Double(...)`.
- Return a `Set` — membership is all the caller needs.

## Step 2 — Cross-check in `ExtractedReceipt.build`

**File:** `Shared/ReceiptModels.swift`, `ExtractedReceipt.build`

`sourceText` is already a parameter (added by the date guardrail) — reuse it,
no signature change.

In the existing amount-validation area, after the current empty/non-numeric
checks:

```swift
if let sourceText, !amount.isEmpty, Double(amount) != nil {
    let printed = ReceiptAmountDetector.amounts(in: sourceText)
    let normalized = String(format: "%.2f", Double(amount)!)
    // Empty means no currency figures were recognized at all — can't verify,
    // which is NOT evidence of invention. Same reasoning as the date check.
    if !printed.isEmpty && !printed.contains(normalized) {
        needsReview = true
        if reason.isEmpty {
            reason = "Amount $\(amount) isn't printed on this receipt — please check it."
        }
    }
}
```

Flag only. Do not modify `amount`.

## Step 3 — Interrupt at submit time and offer a re-shoot

**File:** `Shared/ReceiptSubmitView.swift`

There is already an exact precedent: the `.needsDate` state
(`SubmitState` enum ~line 56, UI ~line 177, triggered ~line 265). It stops
after saving, explains what couldn't be read, and lets the user fix it right
then. Mirror it with `.needsAmount`.

Why at submit time rather than only a review flag: the user still has the
receipt in front of them and can retake the photo immediately. A flag in the
list gets noticed days later, when the paper is gone.

Trigger it the same way `.needsDate` is triggered — by matching the review
reason `ExtractedReceipt.build` wrote (see `unreadableDateReasonSuffix` for
the existing pattern; match a distinctive substring, not the whole string).

The UI block should say roughly:

> **Couldn't read the amount on this receipt**
> The amount saved doesn't appear on the receipt. Check it below, or take a
> clearer photo — **Scan Receipt** usually reads far better than Take Photo.

with an editable amount field + Save, and a "Skip for now — it stays flagged
for review" escape, matching `.needsDate`'s shape.

**Scope note:** `ReceiptSubmitView` lives in `Shared/` and is also used by the
share extension, which cannot re-open the camera. Keep the copy advisory
("take a clearer photo with Scan Receipt") rather than adding a button that
launches capture — a live re-shoot button belongs in the app target only, and
is out of scope here.

## Step 4 — Rename "Scan Documents" → "Scan Receipt"

**File:** `ReceiptDrop/ReceiptsView.swift:563` — the only occurrence of the
user-facing string.

```swift
Label("Scan Receipt", systemImage: "doc.text.viewfinder")
```

Do **not** rename the underlying `NewReceiptSource.scanDocument` case,
`DocumentScannerView`, or any other symbol — this is a label change only.
Grep for `"Scan Documents"` after editing to confirm none remain.

## Step 5 — Tests

**File:** `ReceiptDropTests/ExtractionLogicTests.swift`

```
ReceiptAmountDetector, on the Naan and Kabob text (PRE-TIP AMT $66.23, blank total):
  - finds "66.23"
  - does NOT contain "142.51"

build(...) with sourceText:
  amount printed on receipt          → NOT flagged, amount unchanged
  amount absent from receipt         → IS flagged, amount UNCHANGED (no auto-correct)  ← the bug
  "245.6" vs printed "$245.60"       → NOT flagged (normalization works)
  sourceText has no currency at all  → NOT flagged (can't verify ≠ invented)
  sourceText: nil                    → identical to current behavior (regression guard)
```

Run the suite and paste real output — "it compiles" is not enough:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ReceiptDrop.xcodeproj -scheme ReceiptDrop \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Do NOT do these

- **Don't auto-correct the amount.** Flag only — see the rationale above.
- **Don't** flag when the detector finds no amounts at all. That means "can't
  verify," not "invented," and would punish correct reads on receipts whose
  formatting the regex misses.
- **Don't** touch the date guardrail, `BillTotalsParser`, or the extraction
  prompts. This is a new, independent check.
- **Don't** rename any Swift symbols in Step 4 — user-facing label only.
- **Don't** add a camera-launching button to `Shared/ReceiptSubmitView` (see
  the share-extension note in Step 3).

## Reminder

`./generate.sh` **must** run after adding `ReceiptAmountDetector.swift`, or
the build fails with "cannot find ReceiptAmountDetector in scope".

Everything here is plain Foundation — genuinely testable on this Mac's
Xcode 15.2, unlike anything Apple-Intelligence-specific.

## Known limitation, worth stating plainly

This only runs where OCR text exists — "On-Device OCR Text" mode and Apple
On-Device's iOS 26 text path. Cloud providers in full-image mode never OCR,
so they pass `sourceText: nil` and are unprotected. Same gap the date
guardrail has; closing it means running a Vision OCR pass purely for
verification, which is a separate decision.
