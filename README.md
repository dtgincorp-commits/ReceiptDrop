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
