# Roadmap: Check a Bill — fully on-device (Apple-only, no third-party AI)

Objective: **Check a Bill works reliably with no Claude/OpenAI/Gemini and no
API keys.** The iPhone (plus, optionally, Apple's own Private Cloud Compute)
does everything. The archival receipt path already works well on-device; this
roadmap is about closing the gap on bill itemization.

Current architecture (verified in code, Aug 2026):

- `Shared/FoundationModelsService.swift → itemizeBill(data:)` runs a
  **3-tier deterministic Vision pipeline** — Tier 1
  `RecognizeDocumentsRequest` table rows, Tier 2 bounding-box row grouping
  (`VisionLayoutService.recognizeRowsViaRawOCR`), Tier 3 price-suffix regex
  over flat OCR text (`recognizeRowsFromOCRText`) — and picks whichever tier
  finds more (name, price) rows.
- Totals come from `BillTotalsParser.extractTotals` (deterministic keywords).
- The on-device LLM is used only for (a) a binary item/skip classification of
  candidate lines (`filterCandidatesViaModel`) and (b) vendor-name extraction.
  It **cannot invent line items** — by design (4K context, no receipt training).
- Private Cloud Compute is wired as a disabled Tier (entitlement not yet
  provisioned; instantiating without it crashes, doesn't throw).

So "Apple Intelligence is failing" ≈ the Vision tiers mis-pair rows, the
totals parser misses, or the classifier mislabels. Each phase below either
fixes that pipeline or upgrades the model behind it — all within Apple's
stack.

Build constraint reminder (from README): this Mac has the iOS 17.2 SDK — the
`canImport(FoundationModels)` / iOS 26 Vision paths **compile out locally**.
Anything touching those APIs is verified on a device build (local branch,
wired) or Xcode Cloud, not on this Mac.

---

## The core finding: Apple ships no semantic layer

Verified Aug 2026 — this reframes every phase below. Azure Document
Intelligence's `prebuilt-receipt` is a model **trained on receipts**: it
already knows a given number is the tax and a given string is the merchant.
Apple ships no equivalent to developers. The layers map like this:

| What Azure does in one call | Apple counterpart |
|---|---|
| OCR the image | Vision `RecognizeTextRequest` — parity or better |
| Tables / rows / columns | Vision `RecognizeDocumentsRequest` (iOS 26) |
| Emails, phones, dates, URLs | Vision's generic data detectors |
| **Tax vs. tip vs. total vs. line item** | **Nothing — no equivalent** |
| Typed receipt schema returned | You construct it yourself |

That last row is the whole story. Everything `itemizeBill` does — 3-tier row
pairing, `BillTotalsParser` keywords, the item/skip classifier — is this repo
hand-building the semantic layer Azure ships pre-trained. **The on-device gap
is domain knowledge, not OCR quality.** Apple reads the characters at least
as well; it just doesn't know what they mean.

Two consequences that change how to read the phases:

- **Phase 1 is not a workaround.** On Apple's stack that hand-built semantic
  layer *is* the product, so investing in it is the correct default, not a
  stopgap until something better arrives.
- **Phase 4 is the only phase that puts real receipt-domain training on the
  device.** That is precisely what it buys, and why nothing cheaper
  substitutes for it. Phases 2 and 3 give bigger/better *general* models —
  helpful, but still generalists.

Azure is now wired into the app as a live provider
(`AzureDocumentIntelligenceService`) and performing well. Treat it as the
**benchmark, not the destination**: "how close is on-device to Azure on the
same bill?" is a far more actionable target than an abstract accuracy number.

---

## Phase 0 — Eval harness (foundation for everything; ~1 evening + collecting photos)

Goal: turn "it isn't working good" into numbers, per failure mode.

### 0.1 Collect fixtures
- 20–30 real bill photos covering: restaurant thermal receipts, retail
  registers, hotel folios, handwritten-total bills, crumpled/low-light shots,
  and at least 3 known-bad ones from your own testing.
- Store in the repo under `BillEvalFixtures/` (bundled into the app target,
  debug builds only): `bill001.jpg` + `bill001.json`, …

### 0.2 Ground truth format (`billNNN.json`)
```json
{
  "vendor": "Casa Oaxaca",
  "items": [{ "name": "Mole Negro", "quantity": 1, "price": 24.00 }],
  "subtotal": 61.00, "tax": 5.49, "serviceCharge": null, "total": 66.49
}
```
- Generate first drafts **in-app** now that Azure is a live provider: switch
  AI Provider to Microsoft Document Intelligence, run each fixture through
  Check a Bill, export the result. No throwaway script needed
  (`tools/azure-eval/azure_extract.py` remains for bulk/offline runs).
- Then **hand-verify every file**. Azure is good, not perfect — ground truth
  has to be actually true or every number downstream is meaningless.

### 0.3 Scoring
- **Item recall / precision**: match extracted↔truth items by price (±0.01)
  plus fuzzy name (case-insensitive, prefix or token overlap). Report
  missed items, phantom items, wrong-price items separately.
- **Totals**: exact-match subtotal / tax / serviceCharge / total (± 0.01),
  plus `hasArithmeticMismatch` correctness (did we flag when we should?).
- **Vendor**: fuzzy match.
- Aggregate: per-fixture pass/fail + overall table.

### 0.4 Runner
- Hidden **debug screen** in the app (visible in DEBUG builds, e.g. behind a
  long-press in Settings): iterates fixtures, runs
  `FoundationModelsService.itemizeBill`, renders the score table, exports
  JSON/CSV via share sheet. Must run on an iOS 26 device — Vision + FM don't
  exist in this Mac's toolchain.
- Pure-logic pieces (`recognizeRowsFromOCRText`, `BillTotalsParser`,
  candidate pre-filter) get unit tests in `ReceiptDropTests/` with
  string-input fixtures — those *do* run locally and guard regressions.

### 0.5 Score Azure on the same fixtures
Run the identical fixture set through the Azure provider and score it with
the same harness. This gives two things the abstract targets can't:

- **A realistic ceiling.** If Azure itself only hits 94% item recall on your
  photos, chasing 98% on-device is chasing noise.
- **A per-bucket gap map.** Where Apple loses to Azure tells you exactly
  which Phase 1 buckets are worth the effort, and which are already at parity.

### Exit criteria
- Baseline numbers recorded (e.g. "item recall 71%, totals 85%"), failures
  bucketed into a taxonomy (see Phase 1 list).
- Azure's score on the same fixtures recorded alongside, as the benchmark
  every later phase is measured against.

---

## Phase 1 — Tune the deterministic pipeline (iOS 26, ships now; highest ROI)

Work the failure buckets from Phase 0, largest first. Expected buckets and
fixes — all in `VisionLayoutService` / `FoundationModelsService` /
`BillTotalsParser`:

1. **Multi-line item names** — name wraps to its own row, price on the next.
   Fix: merge a left-text-only row into the following row's name when that
   row has a price and the y-gap is small.
2. **Quantity columns** — "2 Margarita 24.00" or "Margarita x2". Fix: parse
   leading/trailing qty tokens into `quantity` instead of polluting the name
   (today everything is hardcoded `quantity: "1"`, which also weakens the
   doubled-item badge).
3. **Tier mis-selection** — "more item rows" can pick a tier that found more
   *wrong* rows. Fix: score tiers by reconciliation instead: prefer the tier
   whose items sum closest to the printed subtotal/total.
4. **Price-column confusion** — two price-like columns (qty-price + extended
   price). Fix: cluster right-side x-coordinates; take the rightmost column.
5. **Discount / negative lines** — "-5.00" rows currently fail
   `Double(price)` or get skipped. Decide policy: include as negative items
   (keeps itemsSum reconciliation honest).
6. **Totals parser misses** — add keywords ("amount due", "balance", "total
   due"), tolerate OCR digit confusions (O↔0, l↔1) in amounts, handle
   totals printed on the line *below* their label.
7. **Classifier over/under-skip** — inspect `filterCandidatesViaModel`
   mistakes; tighten the instruction with 2–3 few-shot examples; keep the
   deterministic pre-filter authoritative for unambiguous cases so the model
   only sees genuinely ambiguous lines.

Process: one bucket per commit → re-run eval → keep only changes that move
the numbers. Local unit tests for every parser change.

### Exit criteria
- Target: **≥90% item recall, ≥90% item precision, ≥95% totals accuracy** on
  the fixture set — or **within a few points of Azure's score from 0.5**,
  whichever is the lower bar. Matching a receipt-trained specialist with a
  hand-built semantic layer is the real goal; the absolute numbers are a
  proxy for it.
- If reached, you may already be done — later phases become optional
  hardening rather than requirements.

---

## Phase 2 — Private Cloud Compute entitlement (parallel with Phase 1; low effort)

PCC = Apple's server-side model behind Apple Intelligence, opened to
third-party apps at WWDC26. 32K context, much stronger reasoning, **no API
key, no cost** for developers under 2M first-time downloads (we qualify).
Still Apple-only and private — but it *is* a network call.

**Calibrated expectation (per the core finding above):** PCC is a bigger
*general-purpose* model, not a receipt specialist. It should help most where
the 4K-context on-device model is the actual bottleneck — long bills that
don't fit in context, and ambiguous item/skip classification. It does not
hand you domain knowledge, so do not expect it to match Azure outright.

1. **Apply for the entitlement** (`com.apple.developer.private-cloud-compute`)
   from App Store Connect under Nickhil's paid team (the `main`-branch
   identity that ships to TestFlight). Free Personal Team builds can't carry
   it — same situation as the App Group.
2. Once granted: add it to `project.yml` entitlements for `main`'s identity
   only; enable the already-wired Tier-1 PCC path. Keep the guard strict —
   instantiate `PrivateCloudComputeLanguageModel` **only** when the
   entitlement is provably present (it crashes rather than throws without it).
3. **Respect Offline Mode**: `offlineOnly == true` must skip PCC entirely and
   use the deterministic pipeline. Consider a separate Settings line so users
   know bill checks may use Apple's private cloud.
4. Use PCC where the small model is weakest: hand it the full layout text
   (32K context fits any bill) for item extraction + classification in one
   call, with the deterministic pipeline as cross-check and fallback.
5. Re-run the Phase 0 eval with PCC on vs off; keep whichever configuration
   scores higher per bucket.

### Exit criteria
- Entitlement granted and merged; eval scores with PCC recorded; Offline Mode
  verified to never touch the network.

---

## Phase 3 — iOS 27 multimodal Foundation Models for `itemizeBill`

The archival receipt path already has the iOS 27 image path
(`supportsImageInput`, `Attachment`). Extend the same pattern to bills — the
model sees the *actual two-column image* instead of reconstructed text.

1. New `@Generable` `BillDraft` mirroring the itemization schema (items with
   name/quantity/price as strings, subtotal, tax, serviceCharge, total,
   unreadable-line count) with `@Guide` descriptions matching the cloud
   prompt's rules ("printed line total, no currency symbol", "never invent a
   line").
2. `@available(iOS 27.0, *)` + `SystemLanguageModel.default.capabilities
   .contains(.vision)` gate, exactly like the receipt path. Feed the
   cropped/enhanced image from `ReceiptCropService` (already produced for the
   photo viewer) — better input than the raw capture.
3. **Arbitration, not replacement**: run the multimodal extraction and the
   deterministic pipeline; pick the result whose `itemsSum` reconciles better
   against the printed subtotal/total (reuse the Tier-selection logic from
   Phase 1.3). Deterministic remains the guaranteed fallback (iOS 26 devices,
   vision-incapable models, model errors).
4. **Register `OCRTool` — central to this phase, not optional.** Confirmed at
   WWDC26: iOS 27's Foundation Models ships `OCRTool` and `BarcodeReaderTool`
   as native, model-callable tools backed by Vision. With `OCRTool`
   registered, the model reads *exact* digits through Vision instead of
   inferring them from pixels, while still seeing the image for layout. That
   combination — precise text + visual structure + guided generation into a
   fixed schema — is the closest stock-Apple analog to what Azure's
   prebuilt-receipt model does internally, and is the best realistic shot at
   closing most of the gap without training a model.
5. Verification is device/Xcode-Cloud only — this Mac's toolchain compiles
   these paths out. Add the fixtures screen numbers for: deterministic-only
   vs multimodal vs arbitrated.

### Exit criteria
- Arbitrated pipeline ≥ deterministic pipeline on every eval bucket, and
  strictly better on the merged-item / misfiled-total buckets.

---

## Phase 4 — Custom Core ML receipt model (contingency only)

Only if Phases 1–3 leave the eval below target. This is real ML engineering —
weeks, not evenings.

**What this phase uniquely buys** (see the core finding): it is the *only*
option that puts genuine receipt-domain training on the device. Phases 1–3
give you a hand-built semantic layer plus progressively better general
models; this gives you the specialist. If the Phase 0.5 gap-to-Azure is
still wide after Phase 3, this is the only remaining lever — but confirm the
gap is perception/domain-level first, because if it's parser-level, Phase 1
work is far cheaper and more effective.

1. **Model**: Donut-style (OCR-free, image → structured JSON) fine-tuned on
   CORD + SROIE public receipt datasets, plus your own fixtures for domain
   fit. (LayoutLM-family needs external OCR; Donut doesn't — better fit for
   on-device.) Microsoft's Azure receipt model is cloud-only — ruled out.
2. **Conversion**: PyTorch → Core ML via `coremltools`; quantize (palettize /
   int8) to keep the bundle sane. Expect ~150–250MB added app size — consider
   On-Demand Resources or Background Assets download.
3. **Integration**: new tier inside `itemizeBill` ahead of the deterministic
   pipeline, same arbitration-by-reconciliation as Phase 3. Same
   `ExtractedBill.build` mapping — no downstream changes.
4. **Eval-driven**: the Phase 0 harness is the acceptance gate; fine-tune →
   convert → score loop until it beats the shipped pipeline.

### Trigger criteria (don't start otherwise)
- After Phases 1–3: item recall < 90% or totals accuracy < 95% on fixtures,
  with failure buckets that are clearly perception-level (not parser-level).

---

## Sequencing

```
Week 1        Phase 0 (fixtures + harness) + 0.5 (score Azure) ──┐
Week 1        Phase 2 step 1 (apply for PCC entitlement — paperwork)
Weeks 2–3     Phase 1 buckets, eval-driven                       │  ← likely "good enough" point
When granted  Phase 2 wiring + eval                              │
iOS 27 SDK    Phase 3 multimodal + OCRTool + arbitration
Only if needed Phase 4
```

Cross-cutting rules:
- Every phase is measured by the Phase 0 harness, **against Azure's score on
  the same fixtures** — no change ships without moving (or holding) the
  numbers.
- Feature work lands on `main` (nicknagpal identifiers); local testing via
  `local-dev-dtgincorp` rebase, per README rules.
- The deterministic pipeline is never deleted — it is the universal fallback
  for older devices, Offline Mode, and model failures.

---

## Open decision: does Azure stay?

This document's objective is Apple-only. Azure is now wired in as a working
provider, which creates a fork that should be decided deliberately rather
than by drift:

- **(a) Azure as a dev tool only** — keep it for generating ground truth and
  as the accuracy benchmark, ship on-device to users. This is what the
  roadmap above assumes.
- **(b) Azure as a paid "Pro" tier** — free tier stays on-device, Pro routes
  Check a Bill through Azure. Raised Aug 2026. Viable and the economics work
  ($0.01/bill vs. a $2.99–4.99/mo tier), but it is a materially different
  product: it needs StoreKit subscription plumbing *and* a backend proxy to
  hold the Azure key (an API key cannot ship in the binary), which is the
  first server-side component this project would own. Validate the accuracy
  delta from Phase 0.5 before committing — if a tuned on-device pipeline
  lands close to Azure, the Pro-tier premise is weak.
- **(c) Azure removed** — strictest reading of the objective.

Phase 0.5 produces the number that should decide this. Until then, no
irreversible work in either direction.
