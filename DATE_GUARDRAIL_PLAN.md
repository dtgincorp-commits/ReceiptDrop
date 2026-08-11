# Correct invented dates by checking the AI's answer against the receipt

## In plain English

When the AI reads a receipt, nothing currently checks whether the date it
reports actually *appears* on that receipt. So when the model gets unsure
and substitutes today's date, it sails through every existing check — the
date is well-formed, not in the future, not a year old — and gets saved
silently with no warning. That's the Yellow Chilli bug, and three rounds of
prompt rewording haven't reliably fixed it.

This adds a deterministic second opinion. Before accepting the AI's date, we
scan the receipt's own text for dates using `NSDataDetector` (an Apple API
that's existed since iOS 4 — no AI, no iOS 26 SDK, works on the current
toolchain). When the receipt clearly shows one date and the AI reported a
different one, **we use the date printed on the receipt** and mark the
receipt for review so the correction is visible. Where there's genuine
ambiguity (several dates on the receipt), we flag instead of guessing.

Worth being clear about what the failure actually is: on the Yellow Chilli
scan the model *did* read the date correctly — it wrote "Ordered at 8/8/26
2:29 PM" into the Comments field — it just populated the `workDate` field
with a different value. This is a field-population failure, not a
recognition failure, which is why rewording the prompt hasn't fixed it and
why a deterministic cross-check is the right tool.

Verified empirically before writing this plan — `NSDataDetector` on the real
Yellow Chilli receipt text returns `2026-08-08 14:29` from the line
`Ordered: 8/8/26 2:29 PM`, i.e. exactly the date the model got wrong.

## Why this beats the alternatives

- Works on **every provider** (Claude/OpenAI/Gemini/Perplexity/Apple), not
  just Apple — all of them can hallucinate a date, and today nothing catches it.
- Works on the **current SDK**. `RecognizeDocumentsRequest.detectedData` was
  the other candidate but needs the iOS 26 SDK we don't have yet.
- **Testable on this Mac right now**, unlike prompt changes, which can only
  be validated by shipping a build and re-scanning on a phone.

---

## Step 1 — Build the date detector

**New file:** `Shared/ReceiptDateDetector.swift`

```swift
enum ReceiptDateDetector {
    /// Dates actually printed in this text, normalized to day granularity.
    static func dates(in text: String) -> [Date]
}
```

Implementation notes:

- Use `NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)`,
  iterate `matches(in:options:range:)`, collect `match.date`.
- **Filter out time-only matches.** A bare `Time  2:30 PM` line (present on
  the Yellow Chilli receipt) is detected as a date on *today* — which would
  make today's date look "present on the receipt" and defeat the entire
  check. Reject any match whose matched substring is only a clock time:
  `^\s*\d{1,2}:\d{2}(:\d{2})?\s*([AaPp]\.?[Mm]\.?)?\s*$`
  Get the substring via `Range(match.range, in: text)`.
- Normalize results with `Calendar.current.startOfDay(for:)` — we compare
  calendar days, never times.
- Return de-duplicated days.

## Step 2 — Use it inside `ExtractedReceipt.build`

**File:** `Shared/ReceiptModels.swift`, `ExtractedReceipt.build` (~line 173)

Add one optional parameter, defaulted so nothing changes for callers that
don't pass it:

```swift
static func build(vendor: String, rawWorkDate: String, amount: String,
                  comments: String, rawVendorType: String,
                  modelReportedLowConfidence: Bool, modelReason: String,
                  sourceText: String? = nil) -> ExtractedReceipt
```

Inside the existing `if let parsed = ClaudeService.flexibleDate(rawWorkDate)`
branch — alongside the current future-date and over-a-year-old checks — apply
this tiered rule. Note `workDate` in the returned `ExtractedReceipt` may now
be **replaced**, so it needs to be a `var` the branch can update rather than
always `ClaudeService.normalizeDate(rawWorkDate)`:

| Detector finds | AI's date | Action |
|---|---|---|
| Exactly 1 date | disagrees with it | **Use the detected date.** Mark `needsReview` so the correction is visible. |
| Multiple dates | is one of them | Accept as-is. The model picked a real date off the receipt. |
| Multiple dates | is none of them | Flag for review, name what was found. Real ambiguity — don't guess. |
| No dates | anything | Leave alone. Detector doesn't recognize this format; absence of evidence isn't evidence of invention. |

```swift
var resolvedWorkDate = ClaudeService.normalizeDate(rawWorkDate)

if let sourceText {
    let printed = ReceiptDateDetector.dates(in: sourceText)
    let parsedDay = Calendar.current.startOfDay(for: parsed)
    // An empty result means "this receipt's date format is one
    // NSDataDetector doesn't recognize", NOT "the AI invented it" —
    // acting on it would punish correct reads on unusual receipts.
    if !printed.isEmpty && !printed.contains(parsedDay) {
        needsReview = true
        if printed.count == 1 {
            // Unambiguous: the receipt shows exactly one date and it isn't
            // the one the model reported. Deterministic text beats model
            // inference — take the printed date. Still flagged, so the
            // correction is visible rather than silent, but the *stored*
            // value is right even if the user never looks.
            resolvedWorkDate = <printed[0] formatted as AppConstants.sheetDateFormat>
            if reason.isEmpty {
                reason = "Date corrected to \(resolvedWorkDate) — the receipt shows that, not \(rawWorkDate). Please confirm."
            }
        } else if reason.isEmpty {
            reason = "Date \(rawWorkDate) doesn't appear on this receipt. Please confirm."
        }
    }
}
```

Then return `workDate: resolvedWorkDate` instead of recomputing
`normalizeDate(rawWorkDate)` at the end of the function.

**Why auto-correct here rather than flag-only:** under flag-only, a user who
doesn't notice the warning keeps *wrong* data. Under auto-correct, a user who
doesn't notice keeps *right* data and the flag is just showing its work. The
risk being traded away — the detector grabbing an expiry or "valid until"
date — is specifically the multi-date case, which this rule still refuses to
guess at.

## Step 3 — Pass the receipt text where we already have it

These call sites already hold the OCR text and can pass it for free, with no
extra work per scan:

- `Shared/FoundationModelsService.swift` — the `extract(ocrText:)` path
  (~line 261)
- `Shared/ClaudeService.swift` — the `extract(ocrText:)` variants for Claude,
  OpenAI, Gemini, and Perplexity (the `build` calls near lines 183, 629, 737,
  839 — confirm which of each pair is the text path before editing)

Leave the **full-image** paths passing `nil` for now (see Step 5). Those
never OCR, so validating them costs an extra Vision pass — worth doing, but
as a deliberate follow-up rather than bundled in here.

Note this means users on "On-Device OCR Text" mode get the guardrail
immediately, and Apple On-Device gets it on the iOS 26 text path — which is
exactly the configuration that produced the reported bug.

## Step 4 — Tests

**File:** `ReceiptDropTests/ExtractionLogicTests.swift`

Required cases:

```
Detector, on the real Yellow Chilli receipt text:
  - finds 2026-08-08
  - does NOT include today (proves the bare "Time 2:30 PM" line is filtered)

build(...) behavior — assert BOTH the stored workDate and the flag:
  single date on receipt (8/8/26), model returned "2026-08-08"
      → workDate == "2026-08-08", NOT flagged
  single date on receipt (8/8/26), model returned today's date
      → workDate == "2026-08-08"  ← CORRECTED, this is the bug
      → IS flagged, reason mentions the correction
  multiple dates on receipt, model returned one of them
      → workDate unchanged, NOT flagged
  multiple dates on receipt, model returned a date that's on neither
      → workDate unchanged (no guessing), IS flagged
  sourceText given but detector finds no dates
      → workDate unchanged, NOT flagged
  sourceText: nil
      → identical to current behavior (regression guard)
```

Run the suite and paste the real output — "it compiles" is not enough:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ReceiptDrop.xcodeproj -scheme ReceiptDrop \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:ReceiptDropTests/ExtractionLogicTests
```

## Step 5 — Explicitly out of scope for this change

- **Don't** wire validation into the full-image paths yet. It needs an extra
  `VisionOCRService.recognizeText` call per scan; decide that separately once
  we've seen the guardrail work on the text paths.
- **Don't** auto-correct when the AI returned *no* date at all. That case
  currently defaults to today and flags, and it stays that way. Filling it
  from a single detected date is tempting, but "AI found no date" plus
  "some date-shaped string exists on the receipt" are two weak signals, and
  combining them is exactly where an expiry or "valid until" date would sneak
  in. Separate change, separate testing.
- **Don't** auto-correct when multiple dates were detected — flag only, per
  the table in Step 2.
- **Don't** touch `flexibleDate`. (Using `NSDataDetector` as a fallback there
  is a genuinely good idea — it parsed every format correctly in testing,
  including `8-8-26`, which `flexibleDate` needed a patch for — but it's a
  separate change with its own regression risk.)
- **Don't** revert the prompt fixes already shipped. They may well be helping;
  this is a safety net underneath them, not a replacement.

## Reminder about the build environment

`./generate.sh` **must** be run after adding `ReceiptDateDetector.swift`, or
the new file won't be in the Xcode project and the build will fail with
"cannot find ReceiptDateDetector in scope".

Everything here is plain Foundation — no `FoundationModels`, no iOS 26 SDK —
so unlike the Apple Intelligence code, it genuinely compiles and runs on this
Mac's Xcode 15.2.
