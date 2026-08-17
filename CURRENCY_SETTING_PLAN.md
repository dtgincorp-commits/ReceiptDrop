# Currency Setting — Implementation Plan (Scope A)

Adds a user-selectable display currency, and makes the deterministic amount
detector work on receipts printed with non-US number conventions.

**Scope A only.** Per-receipt currency (mixed-currency histories, FX-converted
totals) is explicitly out of scope — see "Deliberately out of scope" below.

---

## Why

Two separate problems, found by audit:

1. **Inconsistent currency display.** `ReceiptsView.currencyString()` already
   renders spending totals via `NumberFormatter(.currency)` with no explicit
   locale, so it picks up the device region automatically and shows `₹`/`€`.
   But the amount entry fields hardcode `Text("$")`. An Indian user sees `$`
   on the entry screen and `₹` on the totals screen — same number, same app.

2. **The no-AI amount guardrail is effectively off outside the US.**
   `ReceiptAmountDetector`'s regex assumes `,` = grouping and `.` = decimal.
   On a European receipt reading `1.234,56` it silently matches `1.23`; on an
   Indian lakh-grouped `1,23,456.78` it matches `456.78`. Because the detector
   is flag-only (never auto-corrects), the damage is spurious "amount isn't
   printed on this receipt" warnings and a dead safety net — not corrupted
   saved data. Still worth fixing: this guardrail was built specifically to
   catch AI-fabricated totals.

**These two fixes are independent.** An earlier framing claimed the parser fix
needed the currency setting to disambiguate `1.234,56`. That was wrong — the
last-separator-wins heuristic below resolves it with no setting at all, and
it has to, because the receipt's printed format depends on where the *receipt*
was printed, not on where the phone is. A US traveler scanning a German
receipt needs `1.234,56` parsed correctly regardless of any app setting.

---

## Part 1 — `AppCurrency` enum

New file `Shared/AppCurrency.swift`. Mirror the existing `Shared/AppTextSize.swift`
structure exactly (same `String, CaseIterable, Identifiable` shape, same
`displayName` convention).

```swift
enum AppCurrency: String, CaseIterable, Identifiable {
    case auto, usd, eur, gbp, inr, cad, aud, jpy
}
```

- `id` → `rawValue`
- `displayName` → `"Automatic"`, `"US Dollar ($)"`, `"Euro (€)"`,
  `"British Pound (£)"`, `"Indian Rupee (₹)"`, `"Canadian Dollar (CA$)"`,
  `"Australian Dollar (A$)"`, `"Japanese Yen (¥)"`
- `symbol` → hardcode the symbol per case; for `.auto` return
  `Locale.current.currencySymbol ?? "$"`. Hardcoding is deliberate — more
  predictable than a locale lookup that varies by device region.
- `currencyCode` → `nil` for `.auto` (let `NumberFormatter` use its default),
  otherwise the uppercased ISO code (`"USD"`, `"EUR"`, …).

Default is `.auto`, so an unmodified install keeps today's behaviour of
following the iPhone's region.

## Part 2 — Settings key + picker

- `Shared/AppConstants.swift` → add to `DefaultsKeys`, following the existing
  comment style:
  ```swift
  static let appCurrency = "appCurrency"   // display currency; see AppCurrency
  ```
- `ReceiptDrop/SettingsView.swift` → add an `@AppStorage` matching the
  `appTextSize` declaration exactly (same `store: UserDefaults(suiteName:
  AppConstants.appGroupID)` so it syncs live across views), and add a
  `Section` with a `Picker` immediately after the existing Text Size section.

  **Use the default picker style — NOT `.pickerStyle(.segmented)`.** Eight
  options will not fit a segmented control; the Text Size section uses
  segmented only because it has four short labels.

  Footer text: explain that this changes how amounts are *displayed*, that
  "Automatic" follows the iPhone's region setting, and that it does not
  convert between currencies or change already-saved amounts.

## Part 3 — Replace the hardcoded `$`

Four sites, all the same `HStack { Text("$"); TextField("Amount", …) }` shape.
Each view needs the same `@AppStorage` declaration as above, then
`Text(appCurrency.symbol)`:

- `Shared/ReceiptSubmitView.swift:129`
- `Shared/ReceiptSubmitView.swift:239`
- `ReceiptDrop/EditReceiptView.swift:81`
- `ReceiptDrop/ManualReceiptEntryView.swift:37`

And make the totals formatter respect the setting —
`ReceiptDrop/ReceiptsView.swift:288` `currencyString()`: set
`formatter.currencyCode` when `AppCurrency.currencyCode` is non-nil, leaving
the existing locale-derived behaviour intact for `.auto`. Keep the existing
`maximumFractionDigits = 0` and the `?? "$\(Int(value))"` fallback shape.

## Part 4 — Locale-agnostic amount parsing

This is the substantive part. `Shared/ReceiptAmountDetector.swift`.

### Regex

Current pattern requires `$` or a period-decimal. Generalize to: a leading
currency symbol **or** at least one separator. Bare integers must still be
rejected — that rule exists because `SEQ #`, `Batch #`, `INVOICE` and
`Approval Code` values on card receipts are bare integers, and was verified
against a real receipt before landing.

```
[$€£₹¥]\s*\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d{1,3}(?:[.,]\d{3})*[.,]\d{1,2}
```

### Separator normalization

Replace the current `.replacingOccurrences(of: ",", with: "")` +
`Double(raw)` with a helper implementing **last-separator-wins**:

1. Strip currency symbols and whitespace.
2. **Both `,` and `.` present** → whichever occurs *last* is the decimal
   separator; the other is grouping. Remove grouping chars, convert the
   decimal char to `.`.
   - `1.234,56` → `1234.56`
   - `1,234.56` → `1234.56`
   - `1,23,456.78` → `123456.78`
3. **Only one separator character, occurring more than once** → grouping.
   Remove all.
   - `1.234.567` → `1234567`
4. **Only one separator character, occurring once** → count the digits after
   it. Exactly 3 → grouping (remove it). Otherwise (1 or 2) → decimal
   separator (convert to `.`).
   - `1,234` → `1234`   ·   `342,39` → `342.39`   ·   `12.5` → `12.5`
5. **No separator** → parse as-is.

Rule 4 has one genuinely ambiguous case: `1.234` could be €1234 or $1.234.
Treat as grouping (the rule as written already does). Document this in a
comment — three decimal places on a receipt total is far rarer than European
thousands grouping.

Keep the existing `String(format: "%.2f", value)` output normalization so
callers can still compare by set membership.

### Shared symbol stripping

Three sites strip `$` only. Add one shared helper (a `String` extension or a
static on `AppCurrency`) that strips any supported symbol, and use it in all
three rather than repeating a character set:

- `Shared/ReceiptAmountDetector.swift:37`
- `Shared/FoundationModelsService.swift:419`
- `ReceiptDrop/ReceiptsView.swift:156` (search query parsing — lets a user
  search `>₹500`, not just `>$500`)

## Part 5 — Tests

Add to `ReceiptDropTests/ExtractionLogicTests.swift`, following the existing
naming style:

- Each normalization rule above, asserting the exact parsed value:
  `1.234,56` · `1,234.56` · `1,23,456.78` · `1.234.567` · `342,39` · `1,234` ·
  `12.5` · `1.234`
- Symbol-prefixed detection for each of `$ € £ ₹ ¥`
- **Regression:** bare integers on a card receipt (`SEQ #`, `Batch #`,
  `INVOICE`, `Approval Code` lines) still produce no matches. This is the
  property most at risk from loosening the regex — do not let it break.
- Existing amount-detector tests must all still pass unchanged.

---

## Deliberately out of scope

Do **not** change any of these:

- **`HistoryEntry`** — no per-receipt currency field. That is Scope B, and it
  requires solving mixed-currency totals (`ReceiptsView.swift:285` sums every
  amount into one `Double`; you cannot add ₹ and $ without exchange rates).
- **Stored amount format** — amounts stay plain `"342.39"` strings: period
  decimal, no grouping, no symbol. Only *display* and *input parsing* change.
- **Any `en_US_POSIX` date formatter, or `AppConstants.sheetDateFormat`.**
  Fixed-format + `en_US_POSIX` is Apple's recommended pattern for
  machine-readable dates that must not shift with user locale. It is correct
  as-is.
- **AI prompts** — verified they don't hardcode "dollar" (only code comments
  mention it), so cloud extraction already handles foreign receipts.
- **CSV / Google Sheets output** — column format unchanged.

## Verification

Full suite green, and confirm no regression in the existing amount-detector
and duplicate-detection tests specifically.
