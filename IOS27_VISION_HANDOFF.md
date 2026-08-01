# Handoff: iOS 27 image-input for on-device receipt/bill reading

For Nickhil (or whoever has Xcode 27 / the iOS 27 SDK) to implement. This is
**not committed to the repo** — it's a spec for a feature Neeraj can't build
or type-check locally (this Mac only has the iOS 17.2 SDK, so
`#if canImport(FoundationModels)` code compiles out entirely here). Everything
below has been verified in the codebase as it stands on `main`, current as of
the push containing commit `2f98f44`.

## The problem this fixes

Both on-device paths — regular receipt extraction and "Check a Bill"
itemization — currently work like this:

```
photo → Vision OCR (flatten to plain text) → on-device LanguageModelSession → structured fields
```

That OCR-flattening step throws away the receipt's two-column spatial layout
(item name on the left, price on the right). On a real receipt (Eureka
restaurant, tested 2026-07-28) this produced a genuinely bad read: two line
items merged together, a marketing footer ("Join Eureka's FWB Loyalty Club!")
hallucinated as a $19.75 line item, and the grand total misfiled into the
`service_charge` field instead of `total`. Cloud providers (Claude/Gemini)
don't have this problem because they're sent the actual image, not
OCR'd text.

**iOS 27's Foundation Models framework adds image input for third-party
apps** — the on-device model will accept image attachments directly in a
prompt, the same way Apple's own Visual Intelligence reads a photo. That's
the real fix: skip OCR entirely, hand the model the receipt image.

We're not trying to compete with Apple's own iOS 27 bill-splitter (Apple
Cash / Visual Intelligence) — this app's job is accurate **tax-record
logging**, not settling a group bill. We just want the same underlying
image-understanding accuracy for that purpose.

## What to build

Two call sites need the same treatment, both in `Shared/FoundationModelsService.swift`:

1. `FoundationModelsService.extract(data:kind:categoryContext:)` (line 127) —
   regular receipt/invoice extraction.
2. `FoundationModelsService.itemizeBill(data:)` (line 201) — Check-a-Bill
   itemization. This is the one where the bad read actually happened, so
   it's the higher-value target if you only have time for one.

For each, the shape of the change is: instead of

```swift
let ocrText = (try? await VisionOCRService.recognizeText(in: data)) ?? ""
let session = LanguageModelSession(instructions: instructions)
let response = try await session.respond(to: prompt, generating: BillDraft.self)
```

you want something like (exact API TBD — see "What you need to verify" below):

```swift
let session = LanguageModelSession(instructions: instructions)
let response = try await session.respond(
    to: [.text(prompt), .image(uiImage)],   // or whatever the real attachment API looks like
    generating: BillDraft.self)
```

i.e. attach the receipt image (as `UIImage`/`CGImage`/`CIImage`/file URL —
check what the SDK actually accepts) to the prompt instead of pre-OCR'ing it
to text, and drop the "text recognized via on-device OCR, may contain noise"
framing from the instructions/prompt since the model is now looking at the
real image.

**Keep the existing OCR-text path as a fallback**, gated `#if os(iOS)` /
`@available(iOS 27.0, *)` with an `if #available` branch that falls through to
the current iOS 26 OCR-based code on older OS versions — the same pattern
already used for `@available(iOS 26.0, *)` throughout this file. Don't delete
the iOS 26 path; most testers/users won't be on iOS 27 immediately.

The `@Generable` draft structs (`ReceiptDraft`, `BillItemDraft`/`BillDraft`)
should NOT need to change — they describe the *output* shape, which is
unaffected by whether the *input* was text or an image.

## What you need to verify (can't be confirmed without the real SDK)

- The exact method/type for attaching an image to a `LanguageModelSession`
  prompt — is it a `Prompt` builder with `.image(_:)`, a different
  `respond(to:)` overload, something on `Transcript`? Check
  Apple's iOS 27 Foundation Models docs / WWDC26 session "What's new in
  Foundation Models" directly — don't guess the signature.
- What image types it accepts (`UIImage` vs `CGImage` vs `CIImage` vs
  `Data` vs a file `URL`) and any size/format constraints.
- Whether there's a token/cost budget difference for image vs. text input
  that changes how large a receipt photo you can safely send.

## Where NOT to change anything

- `Shared/BillItemizationService.swift` and the `ReceiptExtractor` protocol
  dispatch — these just call into `FoundationModelsService`; they don't need
  to know whether the on-device path is OCR-based or image-based.
- `Shared/ClaudeService.swift` (cloud providers) — untouched, already sends
  images.
- The `ExtractedBill`/`ExtractedReceipt` model types, `BillReviewView.swift`'s
  arithmetic self-check (`hasArithmeticMismatch`/`totalsUnverifiable`) — these
  are model-agnostic safety nets that stay valuable regardless of how the
  on-device model gets its input, and don't need changes for this work.

## Build/ship path

Neeraj can't compile or type-check `@available(iOS 27.0, *)` code on his Mac
(Xcode 15.2, iOS 17.2 SDK — it just compiles out under `#if canImport`). The
agreed path:

1. You write and locally verify the code with Xcode 27 / iOS 27 SDK.
2. Push to a branch or directly to `main` (whichever you're set up for).
3. If pushing to `main` yourself isn't your normal flow, sync as usual and
   set the Xcode Cloud workflow's Xcode version to 27 so it builds against
   the right SDK.
4. Test on your iOS 27 iPhone via TestFlight.

If you want Neeraj to review the diff before it ships, send it over — he
can read Swift fine, he just can't compile this particular code locally.

## Reference

- Full architecture context: `Shared/FoundationModelsService.swift` header
  comment (lines 11–32) already flags this exact gap with a NOTE pointing at
  `extract(data:kind:)`.
- Ship/sync workflow (fork sync, Xcode Cloud, TestFlight): `NICKHIL_HANDOFF.md`.
- Two-branch/identifier setup: `README.md`.
