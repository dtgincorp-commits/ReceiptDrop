# Let Restore reattach photos to receipts you already have

## In plain English

Your receipts are stored as two separate things: **the list** (vendor, date,
amount, category — small text) and **the photos** (large image files).

The app deliberately keeps photos out of iCloud, which is the privacy promise
on the Settings screen. But nothing ever excluded the list, so the list *does*
get backed up to iCloud.

So after losing a phone and restoring a new one from iCloud, you open
ReceiptDrop and see **every receipt listed correctly, with every photo
missing**. Not an empty app — a complete ledger full of broken thumbnails.

And the existing "Restore from a Backup Zip" feature can't fix it. That
feature was built for a different job (merging receipts in from *another*
phone), so for each receipt in the zip it asks "do I already have this one?"
and skips it if so — photo included. After an iCloud restore you already have
all of them, so restore skips every single one and puts back nothing. It
appears to succeed and changes nothing.

**This plan makes restore also reattach missing photos to receipts already in
the list.**

## Why this approach (and not the alternative)

The alternative considered was excluding the list from iCloud too, so a new
phone would show an empty app and could prompt to restore. Rejected: this is
a tax-records app, so the ledger is the valuable part and the photos are
supporting evidence. That change would mean anyone who never made a backup
zip loses *everything* instead of just images. The current split — small
valuable metadata survives in iCloud, large private images don't — is
actually the right one. The only real bug is restore's inability to reattach.

---

## Step 1 — Copy files for existing entries, not just new ones

**File:** `Shared/ReceiptModels.swift`, `RestoreService.restore` (~line 817)

Today:

```swift
let existingIDs = Set(SubmissionStore.loadHistory().map { $0.id })
let newEntries = backupEntries.filter { !existingIDs.contains($0.id) }

for entry in newEntries {          // ← only new ones get their files copied
    ...
    try? LocalReceiptStore.importFile(from: sourceURL, category: entry.category, filename: filename)
}
```

Change the file-copy loop to iterate **`backupEntries`** (all of them) rather
than `newEntries`. Keep `newEntries` exactly as it is — it's still what
`SubmissionStore.mergeHistory` uses and what the "restored / skipped" counts
are based on; only the file loop changes.

This is safe because `LocalReceiptStore.importFile` (line 410) already
early-returns when the destination exists:

```swift
guard !FileManager.default.fileExists(atPath: destURL.path) else { return }
```

So receipts whose photos are already present are untouched — no overwriting,
no duplicate files, no extra work beyond a `fileExists` check per file.

**Also handle the category-remap case.** When `targetCategory` is set, files
belong under the target category. The existing loop already uses
`sourceCategories[entry.id]` for the source path and `entry.category` for the
destination — that logic is correct as-is and must be preserved when the loop
changes.

## Step 2 — Count and report what was reattached

**File:** `Shared/ReceiptModels.swift`, `RestoreSummary` (~line 717)

Add:

```swift
/// Photos reattached to receipts that were already in the list — the
/// device-restore case, where iCloud brought back the ledger but not the
/// (deliberately excluded) image files.
var photosReattached = 0
```

Increment it whenever a file is actually copied for an entry whose ID was
**already** in `existingIDs`. Note `importFile` returns `Void` and silently
no-ops when the file exists, so the count needs a `FileManager.default
.fileExists(atPath:)` check on the destination *before* calling it —
otherwise every skip would be counted as a reattach. Either do that check
inline, or have `importFile` return `Bool` (`true` = copied) and use that;
the return-value version is cleaner but touches a shared helper, so either is
acceptable.

## Step 3 — Surface it in the restore result

**File:** `ReceiptDrop/SettingsView.swift`, the `restore(from:targetCategory:)`
message construction

Today the message reads:
`"Restored N receipts (M already present)."`

That's actively misleading in the device-restore case — it would say
"0 restored, 47 already present" while having silently fixed 47 photos.

Append when `photosReattached > 0`:
`" Reattached N missing photo(s) to receipts already on this phone."`

## Step 4 — Tests

**File:** `ReceiptDropTests/` (new or existing test file)

`RestoreService.restore` does real filesystem and App Group work, so a full
end-to-end test may be impractical. At minimum, test what can be tested
directly and say plainly which parts are covered:

```
importFile:
  - copies when destination is absent
  - no-ops (does not overwrite) when destination exists   ← the safety property
    the whole change relies on
```

If a full restore test is feasible with a temp directory and a synthetic zip,
cover:
```
  - entry already in history, file missing on disk  → file copied, photosReattached == 1
  - entry already in history, file present          → not copied, photosReattached == 0
  - entry not in history                            → file copied, counted as restored (unchanged)
```

Run the suite and paste actual output — "it compiles" is not enough:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ReceiptDrop.xcodeproj -scheme ReceiptDrop \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:ReceiptDropTests/ExtractionLogicTests
```

## Do NOT do these

- **Don't** change what `newEntries` means or how `mergeHistory` is called —
  the restored/skipped counts must keep working as they do today.
- **Don't** exclude history/categories from iCloud backup. That was the
  rejected alternative; see the rationale above.
- **Don't** make `importFile` overwrite existing files. The `fileExists`
  early-return is load-bearing for this change — overwriting could clobber a
  newer local file with an older one from the zip.
- **Don't** reintroduce the "Include receipts in iCloud backup" toggle. It was
  deliberately reverted as redundant once auto-backup was fixed to bootstrap
  itself.

## Context on uncommitted work

Three finished changes are sitting on `local-dev-dtgincorp`, building clean
but not yet pushed: the light-mode toolbar tint fix, the auto-backup bootstrap
fix (`BackupSettings.isAutoBackupDue`), and the revert of the iCloud toggle.
This plan is independent of all three — but whoever implements it will see
those in `git status`, and they should be committed rather than discarded.
