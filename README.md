# ReceiptDrop

Personal iPhone app for logging receipts (primarily for tax records): share a
receipt photo (or PDF) from any app, or capture one from within the app → pick a
category → the receipt is read by the selected AI provider and saved locally,
organized by category, with a CSV log of every submission. Extraction runs
through **Claude, OpenAI, Gemini, or Apple On-Device (Apple Intelligence)** —
selectable in Settings, with an Offline Mode that keeps everything on-device.
Also includes **Check a Bill**, an at-the-table itemized-bill verification flow
(catch wrong/doubled charges, gratuity already included, suggested tip).

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

## Key identifiers — two sets, one per branch

There are **two** identifier sets. Which one you get depends on the branch you
have checked out. Do not mix them.

| | `main` — the shipping identity | `local-dev-dtgincorp` — local wired builds only |
|---|---|---|
| App bundle ID | `com.nicknagpal.receiptdrop` | `com.dtgincorp.receiptdrop` |
| Extension bundle ID | `com.nicknagpal.receiptdrop.share` | `com.dtgincorp.receiptdrop.share` |
| Tests bundle ID | `com.nicknagpal.receiptdrop.tests` | `com.dtgincorp.receiptdrop.tests` |
| **App Group** | `group.com.nicknagpal.receiptdrop` | `group.com.dtgincorp.receiptdrop` |
| Signed by | Nickhil's paid Apple Developer Program team (Xcode Cloud, cloud-managed signing) | `Neeraj Nagpal (Personal Team)`, free |
| Goes to | TestFlight → testers | Wired device over USB, nowhere else |
| On GitHub? | Yes — this is what ships | **Never pushed. Never merged into `main`.** |

Claude model: `claude-haiku-4-5` (constant in `Shared/AppConstants.swift`).

### Why the split exists

The App Group is the reason. `group.com.nicknagpal.receiptdrop` is registered
under Nickhil's paid team and is what every existing TestFlight tester's data
lives in — renaming it on `main` would orphan their receipts. But a **free
Personal Team cannot create or use App Groups at all**, so local wired builds
can't sign against the `nicknagpal` group either. Hence a second identifier set
that exists only on the local branch.

The identifiers live in **four** places, all flipped by the single commit at the
tip of `local-dev-dtgincorp` (`LOCAL DEV ONLY: switch identifiers to dtgincorp`):

- `project.yml` (three `PRODUCT_BUNDLE_IDENTIFIER`, two `group.` entries)
- `ReceiptDrop/ReceiptDrop.entitlements`
- `ShareExtension/ShareExtension.entitlements`
- `Shared/AppConstants.swift` (`appGroupID`)

### Rules

1. **Feature work is committed to `main`**, with `nicknagpal` identifiers. That
   is what Xcode Cloud builds and what testers install.
2. To test locally, rebase rather than merge:
   `git checkout local-dev-dtgincorp && git rebase main`. The branch is just
   "main + one identifier-flip commit", so this stays clean.
3. **Never merge `local-dev-dtgincorp` into `main`**, and never cherry-pick the
   identifier-flip commit.
4. **Never commit a `DEVELOPMENT_TEAM` value.** Picking a team in Xcode rewrites
   `ReceiptDrop.xcodeproj/project.pbxproj`. Pushing a Personal Team ID there
   breaks Xcode Cloud's signing and the App Group entitlement. Before every push:
   ```sh
   git diff -- '*.pbxproj' | grep DEVELOPMENT_TEAM   # must print nothing
   ```
5. Switching branches or running `./generate.sh` resets the signing team in
   Xcode — re-pick your Personal Team under Signing & Capabilities on both
   targets. This is expected and must not be committed.
6. On a Personal Team build the App Group entitlement is silently stripped.
   `UserDefaults(suiteName:)` and the file container degrade gracefully;
   `KeychainHelper` falls back to the app's private keychain when the shared
   write is rejected (`errSecMissingEntitlement`, OSStatus `-34018`). Properly
   signed TestFlight builds never hit the fallback.
7. The two builds install as **two separate apps** with separate sandboxes
   ("Receipt Drop" and "ReceiptDrop" on the home screen). Their data is not
   shared. That is correct, not a bug.

## Getting a push to `main` into TestFlight

**A push to this repo's `main` does not, by itself, produce a new TestFlight
build.** Xcode Cloud's Primary Repository (App Store Connect → `ReceiptDrop4545`
→ Xcode Cloud → Settings → Repositories) is set to
**`nickhilnagpal23-dev/ReceiptDrop`** — Nickhil's fork — not this repo
(`dtgincorp-commits/ReceiptDrop`) directly. Forks do not auto-sync with the
repo they were forked from. So the real pipeline is:

```
this repo's main  --(Neeraj pushes)-->  (sits here until synced)
        |
        | fork sync (manual step, below)
        v
nickhilnagpal23-dev/ReceiptDrop main  --(Xcode Cloud watches this)-->  build  -->  TestFlight
```

Every time Neeraj pushes new commits to `main` here, **Nickhil must sync his
fork before Xcode Cloud will see the new commits.** Two ways, either works:

- **GitHub web UI (no terminal):** on `github.com/nickhilnagpal23-dev/ReceiptDrop`,
  click **"Sync fork" → "Update branch"**.
- **Git, from Nickhil's local clone** (`origin` = his fork; add the shared repo
  once as a second remote called `upstream`):
  ```sh
  git remote add upstream https://github.com/dtgincorp-commits/ReceiptDrop.git   # one-time
  git fetch upstream
  git merge upstream/main
  git push origin main
  ```

After syncing, confirm before assuming the new commit is live:

```sh
git log -1 origin/main   # from Nickhil's clone, after `git fetch origin` — must match the shared repo's latest commit hash
```

Then in App Store Connect: **Start Build** (select one specific workflow, not
"All Workflows" — the button is greyed out otherwise), and once it succeeds,
**manually add the build to the TestFlight testers group** — this step does not
happen automatically even with "Enable automatic distribution" checked on the
group, per Apple's documented behavior.

If a build ever looks like it shipped an old commit, the fork being out of sync
is the first thing to check — not a signing or repo problem.

### Retiring the split

The branch exists only because of the free Personal Team. Once Neeraj is a
member of Nickhil's **Apple Developer Program team** (distinct from being an App
Store Connect user — see `HANDOFF.md`) and can select that team in Xcode:

1. Re-pick the DTG team in Signing & Capabilities on both targets.
2. Build `main` directly against `com.nicknagpal.*`.
3. Delete `local-dev-dtgincorp` and this whole section — one identifier set,
   one branch, local and TestFlight builds finally consistent.

## Implementation status

Everything is implemented end-to-end:

- **Share sheet** (`ShareExtension/`) and **in-app capture**
  (`ReceiptDrop/NewReceiptView.swift`, camera or photo library) both feed the
  same shared submit UI (`Shared/ReceiptSubmitView.swift`): pick a category,
  Submit, live progress ("Reading receipt…", "Saving…"). On failure the bytes
  + a queue entry are parked in the App Group for later retry.
- **Submission pipeline** (`Shared/SubmissionPipeline.swift`) — AI extraction →
  local save → history entry. Reused by the main app for retries.
- **Multi-provider extraction** — a `ReceiptExtractor` protocol implemented by
  `ClaudeService`, `OpenAIService`, `GeminiService` (`Shared/ClaudeService.swift`)
  and `FoundationModelsService` (`Shared/FoundationModelsService.swift`, Apple
  On-Device / Apple Intelligence, gated `@available(iOS 26.0)` behind
  `#if canImport(FoundationModels)`). Provider + Offline Mode selectable in
  Settings. On-device extraction is OCR-first (Vision) → on-device model via
  guided generation (`@Generable`). Cloud providers get a base64 image/PDF and a
  forced structured-output call. NOTE: on-device paths compile out on toolchains
  without the iOS 26 SDK — this Mac (iOS 17.2 SDK) cannot type-check them; only
  Xcode Cloud / an iOS 26+ device build verifies them.
- **Check a Bill** (`ReceiptDrop/BillCaptureView.swift`, `BillReviewView.swift`,
  `BillPhotoViewerView.swift`, `ReceiptCropService.swift`,
  `Shared/BillItemizationService.swift`, `BillModels.swift`) — separate itemized
  extraction (a different schema from the archival receipt extraction) for
  at-the-table bill verification: custom torch camera with auto-capture, item
  list with doubled-item/mismatch/gratuity checks, cropped/enhanced photo viewer,
  send/share, and an optional "Save to Receipts" bridge into the archival flow.
- **Vendor-type classification + semantic search** — receipts are classified into
  a fixed vendor-type vocabulary at extraction time (backfillable via "Classify
  Untyped Receipts"); search parses a natural-language query into a structured
  filter. Both have per-provider paths including Apple On-Device.
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
- **Settings / History / Retry Queue** (`ReceiptDrop/`) — AI provider + Offline
  Mode selection, per-provider API key entry (with a "Test Key" check), category
  management, submission history, and a retry queue with per-row + "Retry All"
  retries and swipe-to-delete. Both refresh on foreground.

## API keys

Open **Settings**, pick the AI Provider, and paste that provider's key —
Anthropic (`sk-ant-…`), OpenAI (`sk-…`), or Google Gemini (`AIza…`). Keys are
stored in the shared Keychain and read by the share extension. **Apple On-Device
needs no key** (iOS 26+, Apple-Intelligence-capable iPhone, feature enabled).
On a free Personal Team build the App Group is stripped, so `KeychainHelper`
falls back to the app's private keychain (see the identifiers rules above).

## Viewing your receipts and logs

Open the **Files** app → **On My iPhone** → **ReceiptDrop** → **Receipts** →
pick a category folder. Tap the `_log.csv` file inside to open it in
**Numbers** for a clean spreadsheet view, or tap a receipt image/PDF to view
it directly.

## Managing categories

Settings → **Categories** (or "Manage Categories…" from the Receipts sort
menu) lists every category, its receipt count, and an "Add Category" field.
Tap a category for its detail screen: description (fed to the AI as
context), CSV/folder shortcuts, log rebuild, and two structural actions —
**Rename** and **Merge**.

- **Add** rejects a name that already exists (case-insensitively) rather
  than silently doing nothing — a red error shows under the field instead of
  clearing it as if a new category had been created.
- **Rename** (`Shared/CategoryRenameService.swift`) moves every receipt
  (file, CSV row, comments) from the current name to a new one and updates
  the category list to match. Refuses to rename into a name that already
  exists — that's what Merge is for instead. Backs up first; only proceeds
  if the backup succeeds.
- **Merge** (`Shared/CategoryMergeService.swift`) moves every receipt from
  one category into another, then removes the emptied source category from
  the list. Same backup-first guarantee as Rename. Built specifically to
  clean up a case-mismatched pair like "Sample Category" / "SAMPLE
  CATEGORY" — see the next paragraph — but works for any two categories.

**Why case-mismatched categories can exist at all:** `CategoryStore.add`
uppercases every name it creates, but a receipt's own `category` field keeps
whatever casing it had when saved. Restoring an older backup (or one from
before this uppercasing existed) can recreate a category whose name doesn't
match the case of the receipts sitting under it — the receipt list's
category filter and both actions above compare names case-insensitively
specifically to route around this, but the underlying mismatch is still
worth cleaning up with Rename or Merge when you spot it.
