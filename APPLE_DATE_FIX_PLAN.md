# Fix: Apple On-Device receipts defaulting to today's date

## Root cause (confirmed, not guessed)

Two bugs compound:

1. **Instruction mismatch.** Cloud providers (Claude/OpenAI/Gemini/Perplexity)
   are told to hand back `work_date` "normalized to yyyy-MM-dd"
   (`Shared/ClaudeService.swift:118`, and the equivalent schema strings at
   lines ~550, ~658, ~761). Apple On-Device's `@Guide` on `ReceiptDraft
   .workDate` (`Shared/FoundationModelsService.swift:59`) instead says
   "copied exactly as printed... do not convert or reformat it yourself."
   Apple is the only provider not asked to normalize.

2. **The parser is brittle.** `ClaudeService.flexibleDate`
   (`Shared/ClaudeService.swift:195`) does a full-string match against 13
   fixed `DateFormatter` patterns — no trailing time, no leading label, no
   partial match. Verified empirically (compiled and ran the actual format
   list against sample strings): every date with a time attached fails,
   e.g. `"08/07/2026 3:42 PM"` → no match → `nil`.

Combined: a receipt prints `08/07/2026 3:42 PM` → Apple copies it verbatim
(per its instructions) → `flexibleDate` rejects the whole string because of
the trailing time → `ExtractedReceipt.build` (`Shared/ReceiptModels.swift:201`)
falls into the `else` branch → `"Date unreadable, defaulted to today"`.
Vendor and amount are unaffected because neither goes through this parser.

**Unconfirmed alternative** (flagged, not dismissed): on the iOS 26 path,
Apple's model reads *flattened OCR text*, not the photo — if Vision's OCR
mangled the date line, Apple would return an empty/garbled date while cloud
providers (which see the real image) read it fine. This is a different bug
with a different fix. Phase 3 below adds enough visibility to tell which
one actually happened next time, without deferring the two fixes we're
already sure about.

## Phase 1 — align Apple's instruction with every other provider

**File:** `Shared/FoundationModelsService.swift`, the `@Guide` on
`ReceiptDraft.workDate` (~line 59).

Replace:
> "copied exactly as printed (e.g. \"07/24/26\", \"March 3, 2026\" —
> whatever format is shown, do not convert or reformat it yourself)"

With language matching the cloud providers' `work_date` schema exactly:
> "normalized to yyyy-MM-dd. Empty string if no date is clearly shown —
> never guess or invent one."

Keep the "never guess" clause — that part of the original guide was
correct and isn't the bug.

## Phase 2 — harden `flexibleDate` for every provider, not just Apple

**File:** `Shared/ClaudeService.swift`, `flexibleDate` (~line 195).

Before running the existing 13-pattern match, strip from `trimmed`:

- A trailing clock time: regex `\s*\d{1,2}:\d{2}(:\d{2})?\s*[AaPp][Mm]?\.?\s*$`
  (covers `3:42 PM`, `15:42`, `3:42PM`, `15:42:00`)
- A leading weekday name: `^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\s*`
- A leading label: `^(Date|Receipt Date|Work Date)\s*:?\s*`

Do this with `String.replacingOccurrences(of:with:options:.regularExpression)`
calls chained before the existing `for format in formats` loop — don't touch
the format list itself, this is pure input cleanup ahead of it.

Why here and not just in the Apple path: any provider can ignore its schema
and return a raw string occasionally (model drift, a receipt with unusual
formatting confusing the model into copying literally). This is the actual
defense; Phase 1 just stops it from being *routine* for Apple specifically.

**Required verification before considering this phase done** — extend (or
recreate) the standalone test script from this conversation to prove the
new stripping actually fixes the previously-failing cases without
regressing the passing ones:

```
PASS  "2026-08-07"                (existing — must stay passing)
PASS  "08/07/2026"                (existing — must stay passing)
PASS  "8/7/26"                    (existing — must stay passing)
PASS  "Aug 7, 2026"               (existing — must stay passing)
PASS  "08/07/2026 3:42 PM"        (currently FAILS — must become PASS)
PASS  "08/07/26 15:42"            (currently FAILS — must become PASS)
PASS  "2026-08-07 15:42"          (currently FAILS — must become PASS)
PASS  "08-07-2026 3:42PM"         (currently FAILS — must become PASS)
PASS  "Fri 08/07/2026"            (currently FAILS — must become PASS)
PASS  "Date: 08/07/2026"          (currently FAILS — must become PASS)
FAIL  ""                          (empty stays empty — must stay nil)
FAIL  "not a date at all"         (garbage stays rejected — must stay nil)
```
Run this (compiled Swift snippet, same approach as the earlier ad hoc test)
before and after the change and paste both result sets — don't just assert
it compiles.

## Phase 3 — show the actual rejected string, so this is diagnosable next time

**File:** `Shared/ReceiptModels.swift`, `ExtractedReceipt.build` (~line 201),
the `else` branch that currently sets:
```swift
reason = "Date unreadable, defaulted to today"
```

Change to include what was actually received:
```swift
reason = rawWorkDate.isEmpty
    ? "Date unreadable, defaulted to today"
    : "Couldn't parse date: \"\(rawWorkDate)\" — defaulted to today"
```

Check call sites that match on the exact string
`"Date unreadable, defaulted to today"` before changing this — at minimum
`Shared/ReceiptSubmitView.swift` (`Self.unreadableDateReason`, used to
trigger the "set the date" prompt UI). That match must still work when
`rawWorkDate` is empty (the string is unchanged in that case) — if any
call site needs to match the *non-empty* case too, switch it to a
`hasPrefix`/`contains` check instead of exact equality, and search the
whole repo for the literal string before landing this phase to make sure
nothing else breaks.

## Non-goals / guardrails

- Don't touch the 13-pattern format list itself — the stripping happens
  *before* it, not instead of it.
- Don't change `normalizeDate`'s own fallback-to-today behavior — that's a
  legitimate last resort, not part of this bug.
- No new files needed.
- Build check after each phase:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -project ReceiptDrop.xcodeproj -scheme ReceiptDrop -destination
  'generic/platform=iOS Simulator' -sdk iphonesimulator build`
  (this only proves it compiles — this Mac's SDK doesn't include
  `FoundationModels`, so Phase 1's actual behavior can't be verified on a
  simulator run here; Phase 2's regex stripping runs unconditionally and
  *can* be verified here via the standalone test script.)

## After merging

Ask the user to re-scan the same physical receipt that triggered this
(or a similar one with a printed time) on a real device with Apple
Intelligence, and report the actual `work_date` result. If it still
defaults to today, the unconfirmed OCR-mangling alternative above is the
next thing to chase — Phase 3's improved reason text will show whether
`rawWorkDate` came back empty (OCR problem) or non-empty-but-unparseable
(a format phase 2 still missed).
