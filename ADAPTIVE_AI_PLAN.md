# Adaptive AI Plan — the app works fully without an AI provider

## Goal (one sentence)

No Basic/Pro toggle: the app detects whether a working AI path exists
(saved cloud key, or Apple Intelligence available) and adapts — every
button still does something useful, AI-only features show a friendly
"Connect AI" invite instead of erroring, and connecting AI later simply
lights everything up with zero data migration.

## Why no toggle (decided — do not revisit)

"Has AI" is a fact about the phone, not a preference. The app already
computes it (`AISetupState.currentProviderIsConfigured`, built for the
Connect AI wizard). A manual Pro/Basic switch would be a second source of
truth that can contradict reality, and the keyless users this serves are
exactly the ones who wouldn't know which side of the switch they're on.
Per-receipt opt-out already exists ("Enter Manually"); global opt-out
already exists (Offline Mode).

---

## Phase 0 — move the capability check to Shared

**Problem:** `AISetupState.currentProviderIsConfigured` lives in
`ReceiptDrop/ConnectAIView.swift` (main-app target only), but the capture
fallback must run in `Shared/ReceiptSubmitView.swift` /
`Shared/SubmissionPipeline.swift`, which the share extension also compiles.

**Change:** add to `ExtractionSettings` in `Shared/ReceiptModels.swift`:

```swift
/// True when the currently selected provider can actually run — Apple
/// On-Device is ready, or the provider's key/credentials are saved.
static var aiConfigured: Bool
```

Logic is a move of the existing switch in `AISetupState
.currentProviderIsConfigured` (per-provider KeychainHelper checks; Azure
needs endpoint AND key; `.appleOnDevice` additionally requires
`FoundationModelsService.isModelReady` behind
`#if canImport(FoundationModels)` / `if #available(iOS 26.0, *)` — note
this is *stricter* than the old check, which returned `true` for
appleOnDevice unconditionally; that stricter behavior is intended here).
Then make `AISetupState.currentProviderIsConfigured` a one-line wrapper so
the wizard keeps working. Keep the *evaluation live* (computed each time,
never cached in @State at launch) so connecting AI mid-session takes
effect immediately.

## Phase 1 — capture always works (the core change)

**Today:** keyless user taps Take Photo → photo captured →
`SubmissionPipeline.run` → extractor throws → error, receipt lost.

**Target:** same buttons, same capture; when `!ExtractionSettings
.aiConfigured`, the post-capture screen shows *editable manual fields*
(vendor, amount, date, comments) instead of running extraction, and Submit
saves the photo + CSV row + history exactly like an AI submission.

Changes:

1. **`Shared/SubmissionPipeline.swift`** — add
   `saveWithoutExtraction(data:kind:category:vendor:workDate:amount:comments:) throws -> HistoryEntry`.
   Reuse the tail of `run(...)` (duplicate check on workDate+amount →
   `LocalReceiptStore.save` → `appendLog` → `HistoryEntry` →
   `SubmissionStore.appendHistory`), skipping extraction. Set
   `verificationStatus: .none` (a human typed it — same trust level as
   `recordManualEntry`). Prefer extracting a private shared helper from
   `run`'s tail over copy-paste.

2. **`Shared/ReceiptSubmitView.swift`** — when `!ExtractionSettings
   .aiConfigured`, render the manual-fields form (mirror field validation
   from `ManualReceiptEntryView`: vendor non-empty, amount parses as
   Double) between the existing thumbnail and category picker, and route
   Submit to `saveWithoutExtraction`. Keep the duplicate-alert and
   success/queued UX consistent with the AI path. Add a plain footer:
   "Connect an AI in Settings to fill these in automatically from the
   photo." (Text only — this view is in Shared and must not reference
   ConnectAIView.) This automatically fixes the share extension for
   keyless users too — verify the extension path compiles and behaves.

3. **`ReceiptDrop/ManualReceiptEntryView.swift`** — unchanged. It remains
   the no-photo path.

## Phase 2 — gate the AI-only features with invites, not errors

1. **Check a Bill** (`ReceiptsView.swift`, the `doc.text.magnifyingglass`
   toolbar button → `showBillCapture`): when `!aiConfigured`, present a
   small invite sheet instead of the capture cover: icon + "Check a Bill
   reads a bill line-by-line and needs an AI connected" + button that
   presents `ConnectAIView` (this is main-app code, so referencing the
   wizard is fine) + "Not Now". Do NOT hide the toolbar button — hidden
   features never get discovered.

2. **Natural-language search** (`ReceiptsView.runSemanticSearch()`): when
   `!aiConfigured`, set `semanticError` to "Smart search needs an AI —
   use Settings → Connect AI. Plain text search still works above." and
   return before calling `SemanticSearchService`. Also make the
   `.searchable` prompt adaptive: keyless → "Search receipts"; configured
   → existing "Search, or try \"restaurants over $100\"".

3. **Classify Untyped Receipts** (`SettingsView.classifyUnclassified`):
   when `!aiConfigured`, set `classifyError` to a "needs an AI — use
   Connect AI above" message instead of calling the service.

4. **Scan Text** (`+` menu in `ReceiptsView`): when `!aiConfigured`, hide
   this one item (exception to the no-hiding rule: raw OCR text with no
   AI to structure it has no sensible fallback screen). Optional phase-3
   alternative: route the scanned text into the manual form with the text
   prefilled into Comments.

5. **Insights narrative / auto-Comments / vendor auto-tag:** no changes —
   narrative is already additive-only (numeric digest always renders),
   and the other two simply don't occur without extraction.

## Phase 3 — polish

- **First-run wizard interplay** (`ContentView.maybeShowAISetup`): logic
  unchanged, but with Phase 1 in place, "Set Up Later" now lands in a
  fully working app. Optionally add one dismissible line under the
  Receipts title the first time: "Tip: receipts are typed in by hand
  until you connect an AI (Settings)."
- **Wizard completion refresh:** invite sheets and the searchable prompt
  read `aiConfigured` live; after `ConnectAIView` finishes, re-render
  must reflect connected state (Settings already resets
  `selectedProvider` on dismiss — mirror that where needed).
- **Retry Queue:** entries queued from old keyless failures will still
  fail retry with the provider error — acceptable; out of scope.

## Non-goals / guardrails

- NO Basic/Pro toggle, no new UserDefaults mode flag.
- NO data-format changes: a keyless receipt is a normal
  photo+CSV+history receipt (that's the whole point).
- Don't rename anything "Pro"/"Basic" in UI copy.
- `Shared/` files must not reference `ConnectAIView` (app-target only).
- No new files needed; if one is added anyway, run `./generate.sh`
  before building.
- Build check: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild -project ReceiptDrop.xcodeproj -scheme ReceiptDrop
  -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build`

## Test checklist (simulator = keyless by default: no keys, no Apple Intelligence)

1. Fresh install, "Set Up Later" → Take Photo → manual fields appear with
   thumbnail → fill vendor/amount → Submit → receipt in list with photo,
   CSV row written.
2. Same via Choose from Library and Choose File (PDF).
3. Duplicate typed entry (same category+date+amount) → duplicate alert.
4. Check a Bill → invite sheet, Connect AI opens wizard, Not Now returns.
5. Search: plain text filter works; submitting a phrase shows the
   friendly message, not a raw provider error.
6. Settings → Classify Untyped Receipts → friendly message.
7. Add a Gemini key via wizard → without relaunch: capture runs AI
   extraction again, smart search works, Check a Bill captures.
8. Share extension keyless: share a photo → manual fields → saves.
9. Regression with a key present: all flows identical to today.
