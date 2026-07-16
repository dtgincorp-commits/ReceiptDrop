# ReceiptDrop

Personal iPhone app: share a receipt photo (or PDF) from any app, or capture
one from within the app → pick a category → the receipt is read by Claude and
saved locally, organized by category, with a CSV log of every submission.

## Project layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen config — the source of truth for targets, entitlements, packages. |
| `ReceiptDrop.xcodeproj` | **Generated** — do not hand-edit; regenerate instead. |
| `ReceiptDrop/` | Main app (History, Retry Queue, Settings, in-app camera/library capture). |
| `ShareExtension/` | The share-sheet UI and submission pipeline. |
| `Shared/` | Code compiled into both targets (constants, Keychain, categories, storage, Claude). |

## Regenerating the project

After editing `project.yml` (or if the project file is ever lost):

```sh
~/ReceiptDrop/generate.sh
```

Always use the script, not bare `xcodegen generate` — it patches the project
back to the Xcode 15 file format (new XcodeGen emits the Xcode 16 format,
which crashes Xcode 15.2's project editor).

Note: regenerating resets any signing team you selected in Xcode — re-select
your personal team under Signing & Capabilities for both targets.

## Key identifiers

- App bundle ID: `com.dtgincorp.receiptdrop`
- Extension bundle ID: `com.dtgincorp.receiptdrop.share`
- App Group: `group.com.dtgincorp.receiptdrop`
- Claude model: `claude-haiku-4-5` (constant in `Shared/AppConstants.swift`)

## Implementation status

Everything is implemented end-to-end:

- **Share sheet** (`ShareExtension/`) and **in-app capture**
  (`ReceiptDrop/NewReceiptView.swift`, camera or photo library) both feed the
  same shared submit UI (`Shared/ReceiptSubmitView.swift`): pick a category,
  Submit, live progress ("Reading receipt…", "Saving…"). On failure the bytes
  + a queue entry are parked in the App Group for later retry.
- **Submission pipeline** (`Shared/SubmissionPipeline.swift`) — Claude
  extraction → local save → history entry. Reused by the main app for retries.
- **Claude extraction** (`Shared/ClaudeService.swift`) — Anthropic Messages API
  with a base64 image or PDF document block and a forced `record_receipt` tool
  call for structured JSON.
- **Local storage** (`Shared/LocalReceiptStore.swift`) — no external accounts
  needed. Each category gets its own folder plus a CSV log
  (`<CATEGORY>_log.csv`) with a header row and one line per submission
  (vendor, date, amount, comments, receipt filename). Files land in the
  **Files app** under **On My iPhone → ReceiptDrop → Receipts → \<CATEGORY\>**,
  where the CSV opens cleanly as a table in the **Numbers** app.
  - The share extension can't write directly into the main app's Documents
    (different sandbox), so it spools into the App Group container; the main
    app drains that spool into Documents whenever it's opened or a
    submission/retry completes in-app.
- **Settings / History / Retry Queue** (`ReceiptDrop/`) — Anthropic API key
  entry, category management, submission history, and a retry queue with
  per-row + "Retry All" retries and swipe-to-delete. Both refresh on
  foreground.

## Anthropic API key

Open **Settings → Anthropic API Key** and paste a key (`sk-ant-…`). It is
stored in the shared Keychain and read by the share extension when reading
receipts.

## Viewing your receipts and logs

Open the **Files** app → **On My iPhone** → **ReceiptDrop** → **Receipts** →
pick a category folder. Tap the `_log.csv` file inside to open it in
**Numbers** for a clean spreadsheet view, or tap a receipt image/PDF to view
it directly.
