# Plan: Swap in Apple Intelligence (on-device) for receipt reading

Goal: add an on-device Foundation Models extraction backend so receipts can be
read with Apple Intelligence (iOS 27) instead of the Claude/OpenAI/Gemini
cloud APIs — with **no API key** and **no network**.

The extraction layer is already abstracted behind the `ReceiptExtractor`
protocol, and an `.appleOnDevice` provider case already exists but is gated
off. This is an additive change: Claude/OpenAI/Gemini stay as-is and remain
the fallback for older/ineligible devices.

## Background (verified July 2026)

iOS 27's Foundation Models framework added **image input** (multimodal
prompts) at WWDC 2026 — you can attach a `UIImage`/`CGImage`/`CIImage`/file
URL to a prompt and the on-device model reasons about it, and Vision OCR /
barcode tools are callable by the model on-device. This makes it a real
replacement for the cloud vision path, not just the OCR-text path.

## The seam you plug into

- `Shared/ReceiptModels.swift`
  - `protocol ReceiptExtractor` — two methods: `extract(data:kind:categoryContext:)`
    (image/PDF bytes) and `extract(ocrText:categoryContext:)` (OCR text).
  - `enum ExtractionProvider` — already has `case appleOnDevice`, currently
    `isAvailable == false`.
  - `ExtractionSettings.currentExtractor()` — the factory; `.appleOnDevice`
    currently falls back to `ClaudeService()` (`// unreachable`).
  - `ExtractedReceipt.build(...)` — model-agnostic HITL flagging (empty
    vendor/amount, unparseable/implausible date). Reuse verbatim.
  - `VendorTypeToken.allValidValues` — the vendor-type vocabulary to constrain
    the model's output to (built-ins + user-added custom types).
- `Shared/ClaudeService.swift` — reference implementations + `downscaledJPEG`
  helper + `normalizeDate`. Copy the shape, not the network code.

## Steps

### 1. New file: `Shared/FoundationModelsService.swift`
- `@available(iOS 26.0, *) struct FoundationModelsService: ReceiptExtractor`.
- Define a `@Generable` result struct mirroring the `record_receipt` schema:
  `vendor`, `workDate`, `amount`, `comments`, `vendorType`, plus a
  confidence/`needsReview` signal. Use `@Guide` to constrain `vendorType` to
  `VendorTypeToken.allValidValues`. Guided generation is Apple's equivalent of
  Claude's forced tool call — the model must return validated structured data.
- `extract(data:kind:categoryContext:)`:
  - image: downscale via `ClaudeService.downscaledJPEG`, build an image
    attachment, prompt with `ExtractionPrompt.preamble(categoryContext:)` +
    the extract instruction, call `session.respond(to:generating:)`.
  - pdf: Foundation Models takes images, not PDFs — render each PDF page to a
    `CGImage` (PDFKit / Core Graphics) and attach, OR route PDFs to the
    OCR-text path below. (Note: OpenAIService already punts on PDFs, so a
    PDF→image render is the more complete choice.)
  - Map the `@Generable` result into `ExtractedReceipt.build(...)` — do NOT
    reimplement the HITL logic.
- `extract(ocrText:categoryContext:)`: text-only session + guided generation.
  Simplest path, and Vision OCR already feeds this method today.
- Availability: check `SystemLanguageModel.default.availability`; if
  `.unavailable` (device ineligible or Apple Intelligence off), throw a clear
  error so the UI can message it / fall back.

### 2. Wire it up in `ReceiptModels.swift`
- `ExtractionProvider.appleOnDevice.isAvailable` → true when running iOS 26+
  and the system model reports available. Consider computing this dynamically
  so Settings reflects real device state.
- `ExtractionSettings.currentExtractor()`:
  ```swift
  case .appleOnDevice:
      if #available(iOS 26.0, *) { return FoundationModelsService() }
      return GeminiService() // fallback on older OS
  ```

### 3. No-API-key path
- On-device needs no key. Make sure the submit flow / Settings don't block or
  warn about a missing API key when the provider is `.appleOnDevice`.
  (Grep for `missingAPIKey` and the Settings key-required warning.)

### 4. Settings UI (`ReceiptDrop/SettingsView.swift`)
- The provider picker already disables unavailable options; once `isAvailable`
  is true, `.appleOnDevice` becomes selectable. Add a caption: no key needed,
  requires an Apple Intelligence–capable device with the feature enabled.

### 5. Search query parsing (optional, later)
- `ClaudeService.swift`'s `parseQueryViaGemini` currently also handles
  `.appleOnDevice` for the search box — so search still needs a cloud key even
  when extraction is on-device. Add an on-device query parser later for a
  fully offline experience. Not required for the extraction swap.

## Testing (also addresses the "run tests" goal — there's no test target yet)

- **Foundation Models likely requires a physical device** — the on-device
  model has historically not run in the Simulator. VERIFY on your iOS 27
  hardware; this is where your real iPhone matters vs. the simulator.
- Add a unit-test target to `project.yml` (regenerate with `./generate.sh`).
  Start with model-free, network-free tests — ideal first coverage:
  - `ExtractedReceipt.build(...)` HITL flagging (empty vendor/amount, future
    date, >15-month-old date, unparseable date).
  - `VendorTypeToken.resolve(...)` / `allValidValues`.
  - `ClaudeService.normalizeDate(...)`.
- Then a device-only integration test that runs a sample receipt image through
  `FoundationModelsService` and asserts the fields parse.

## Effort estimate
- New service file: the bulk of the work (~1–2 hrs incl. device testing).
- Wiring (enum + factory + Settings caption): ~20 min — the seam already exists.

## Xcode-format note
`generate.sh` patches the project back to the Xcode 15 file format. If you're
fully on Xcode 27, you can delete that patch block (the README says so) — but
it's harmless to leave.
