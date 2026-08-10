# Fix: dates landing in the wrong year, and prompt text that hides the date

## In plain English

Two separate problems, both about receipt dates.

1. **Dates with a day of 12 or lower get the wrong year.** A receipt dated
   `8/8/26` is being read as the year **2008** instead of **2026**. This
   affects every AI provider, not just Apple. It's a bug in our own Swift
   code, and it's confirmed — not a guess.
2. **Our instructions to the AI point it away from the date.** The prompt
   tells the AI "the date is usually NOT at the top" and only shows it one
   example label: `"Date:"`. The user's Yellow Chilli receipt has the date
   *at the top*, labeled `"Ordered:"`. So we're actively steering the AI
   away from the answer.

Step 1 below is a quick check before writing any code. Steps 2–4 are the
actual work, done in order.

## Important: don't undo the last fix

`APPLE_DATE_FIX_PLAN.md` already shipped (commit `eaecc3f`). Everything in
it is correct and stays: the Apple `@Guide` change, the time-stripping in
`flexibleDate`, and the improved review-reason message. This plan adds to
that work — it does not replace it.

---

## Step 1 — Check something before writing code

The user scanned a receipt printed `Ordered: 8/8/26 2:29 PM` and got today's
date instead. We don't yet know whether that phone was running a build that
*contains* the last fix.

Ask the user to open that receipt in the **Receipts list** (not the Edit
screen) and read the "Needs review — …" line under it:

| If it says | It means |
|---|---|
| `Date unreadable, defaulted to today` | Old build — the last fix isn't on that phone yet |
| `Couldn't parse date: "8/8/26 2:29 PM" — …` | New build, and the parser is still failing |
| *(no review line at all)* | New build, and the AI returned a wrong-but-valid date |

This doesn't block anything below — Steps 2–4 are worth doing either way.
It just tells us whether the original problem is already solved.

---

## Step 2 — Fix dates landing in the wrong year

**File:** `Shared/ClaudeService.swift`, the `flexibleDate` function (~line 195)

### The problem

Swift's `DateFormatter` treats `/` and `-` as interchangeable. Our format
list has `"yyyy-MM-dd"` **first**, so it grabs short US dates before the
correct pattern gets a turn:

```
"8/8/26"    → read as year 8, month 8, day 26  →  2008-08-26   WRONG
"08/08/26"  → same                             →  2008-08-26   WRONG
"8-8-26"    → same                             →  2008-08-26   WRONG

"3/20/24"   → month 20 is invalid, so it falls through correctly → 2024-03-20   OK
"12/25/26"  → month 25 is invalid, so it falls through correctly → 2026-12-25   OK
```

It only breaks when **the day is 12 or lower**. Any higher and the fake
"month" is invalid, the wrong pattern fails, and the right one takes over.
That's roughly 40% of dates.

**This is also why the current tests pass** — every date in
`testNormalizeDateParsesReceiptFormats` uses day **20**, which is safely
above 12. The tests never had a chance to catch it.

### The fix

Only try the `yyyy-MM-dd` pattern when the text actually looks like a real
ISO date. Add this check *before* the format loop, and remove
`"yyyy-MM-dd"` from the `formats` array so it can't grab slash dates:

```swift
// True ISO only, matched by shape first. DateFormatter treats "/" and "-"
// as interchangeable separators, which previously let this pattern claim
// "8/8/26" as year 8 / month 8 / day 26.
if trimmed.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
    formatter.dateFormat = "yyyy-MM-dd"
    if let date = formatter.date(from: trimmed) { return date }
}
```

Leave everything else alone — especially the existing 2-digit-year
promotion logic, which is correct and still needed.

Then confirm `"2026/08/08"` still works. It should: `M/d/yyyy` and `M/d/yy`
both reject month 2026, so `"yyyy/MM/dd"` still catches it.

---

## Step 3 — Stop the prompt from pointing away from the date

**File:** `Shared/ReceiptModels.swift`, `ExtractionPrompt.preamble` (~line 238)

### Careful — this text is shared by all five providers

Claude, OpenAI, Gemini and Perplexity all use this same preamble, and all
four currently read dates fine. Make the smallest change that fixes the
problem. Don't rewrite the whole thing.

### Three changes

1. **Remove the "often NOT at the top" claim.** Say instead that the date
   may be near the top (often next to a check or order number) *or* in the
   payment block near the bottom.
2. **Add more example labels.** Right now it only shows `"Date:"`. Include:
   `Date`, `Ordered`, `Order Date`, `Transaction Date`, `Sale Date`,
   `Served`.
3. **Add a guard against copying today's date**, in words close to:

   > "Today's date is given only so you can judge whether a date you found
   > is plausible. Never output today's date as the receipt's date unless
   > the receipt itself clearly shows that date."

### Keep these exactly as they are

- The "Today's date is …" sentence itself. (Removing it was considered and
  rejected — our Swift code already checks plausibility, so it's arguably
  redundant, but four working providers may rely on that grounding.
  Guarding it is lower-risk than deleting it.)
- The `yyyy-MM-dd` output instruction.
- The 2-digit-year expansion rule.
- The "return an empty string, never guess or invent one" clause.

---

## Step 4 — Add tests that would have caught this

**File:** `ReceiptDropTests/ExtractionLogicTests.swift`

Every new case must use **a day of 12 or lower** — that's the exact gap in
the current tests.

```
"8/8/26"          → "2026-08-08"    (the user's actual receipt)
"1/2/25"          → "2025-01-02"
"08/08/26"        → "2026-08-08"
"8-8-26"          → "2026-08-08"
"8/8/26 2:29 PM"  → "2026-08-08"    (Step 2 + the already-shipped time-stripping)
"2026-08-08"      → "2026-08-08"    (real ISO must still work)
"2026/08/08"      → "2026-08-08"
"12/25/26"        → "2026-12-25"    (day over 12 — must not break)
"3/20/24"         → "2024-03-20"    (existing case — must not break)
```

Run the suite and **paste the actual output**. "It compiles" is not enough:

```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ReceiptDrop.xcodeproj -scheme ReceiptDrop \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:ReceiptDropTests/ExtractionLogicTests
```

These are plain Swift, so unlike the Apple Intelligence code they really
can be verified on this Mac.

---

## Do NOT do these

- **Don't flag a receipt just because its date equals today.** This was
  proposed and rejected. People photograph receipts the same day all the
  time — that's normal use of this app — so it would flag a large number of
  perfectly correct receipts to catch a rare mistake. Step 3's guard
  addresses the cause instead.
- **Don't change anything from `APPLE_DATE_FIX_PLAN.md`.**
- **Don't reorder or delete** the existing 2-digit-year promotion logic.
- No new files needed, so no `./generate.sh` unless you add one.

---

## After it's merged

Have Nickhil rebuild, then re-scan the same Yellow Chilli receipt.

**Expected result:** Work Date = `Aug 8, 2026`.

If it's still wrong, report the exact "Needs review — …" line from the
Receipts list. With Step 2 fixed, that line now tells us the difference
between a parsing failure (it shows the bad text) and the AI inventing a
date (no review line at all) — which is the one question Step 1 leaves open.
