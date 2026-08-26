# Onboarding — make the first scan work

The goal, stated plainly: **a brand-new user must be able to scan their first
receipt and save it.** Quality can be poor. Failing to save at all is what
loses the user.

Ordered by how many users each item would otherwise cost. Items 1–2 are
permanent behavior, not onboarding tricks — see the scope note on each.

---

## 1. Never block the save — PERMANENT, ALL SCANS

**Not an onboarding item. A correctness bug.**

`ReceiptSubmitView.manualFieldsValid` requires a non-empty vendor *and* a
parseable amount before Submit enables. When OCR prefill guesses wrong or comes
back blank — which it does; see the Home Depot receipt that produced "How doers"
as a vendor — Submit sits disabled with nothing explaining why. A first-time
user concludes the app is broken and leaves.

Blocking is just as wrong on receipt #50 as on receipt #1, so this is not
scoped to first run.

**Change:** let the receipt save with whatever it has, flagged `needsReview` —
the same pattern the AI path already uses for an unreadable date or an amount
that isn't printed on the receipt. An empty vendor becomes something like
"Unknown Vendor" rather than a wall.

**Also fixes the share extension**, which runs the same view with the same
validation and has no onboarding of its own (see item 8).

## 2. "Work Date" is jargon — PERMANENT

A first-time user is asked for a **Work Date** before they can save. Nobody
knows what that means: the date printed on the receipt? The date the work was
done? Today? It is a required field asking a question the user cannot
confidently answer.

**Change:** rename to "Receipt Date" (or just "Date") in the UI. Near-zero risk,
removes a real hesitation. Note `HistoryEntry.workDate` and the CSV column are
storage-level names — decide deliberately whether those change too, since the
CSV header is user-visible in exported files and existing logs.

## 3. Default category name — PERMANENT

The seeded default is `SAMPLE CATEGORY`. A first-time user scans a real receipt
and files it into something named like demo data.

**Change:** seed something meaningful ("Business Expenses"?) or ask once during
onboarding what they're tracking. Careful: this is the same category involved in
the case-variant folder collision fixed in `bfcac55`, and
`AppConstants.defaultCategories` is referenced by restore. Check what depends on
the literal string before changing it.

## 4. Empty state should be the call to action — FIRST RUN (mostly)

The Receipts screen currently says "No Receipts Yet — Receipts you submit will
appear here." The only way to act is the "+" in the toolbar. That screen is the
most important moment in the app and it has no button.

**Change:** make the empty state itself the primary action — a real "Scan your
first receipt" button, not a caption.

## 5. Apple Intelligence has a third state — FIRST RUN + SETTINGS

Not just capable / incapable. There is also **capable, enabled, but the model is
still downloading** (several GB). Today that silently falls back to OCR with no
explanation, the user concludes the AI doesn't work, and they never find out it
started working later.

`SystemLanguageModel.availability` distinguishes these — `isModelReady` currently
collapses everything that isn't `.available` into false.

**Change:** detect and surface "downloading" distinctly from "not supported."

## 6. Surface "turn on Apple Intelligence" — FIRST RUN + PERMANENT SETTINGS ENTRY

There is a gap between *device supports it* and *device has it enabled*. A
capable iPhone with Apple Intelligence switched off falls back to OCR silently,
and the user never learns there is a one-tap fix in iOS Settings.

**Change:** treat "capable but not enabled" as its own state in the first-run
screen, with a direct link to Settings → Apple Intelligence & Siri. Show once —
do not nag — but leave a permanent entry point in the app's own Settings for
someone who enables it months later.

## 7. Prime permissions before the system dialog — ONE TIME BY NATURE

iOS asks for camera and photo access exactly once. Cold system dialogs get
reflexive "Don't Allow" taps, and once denied the capture flow dead-ends with
most users not knowing how to re-grant.

**Change:** one short screen explaining why, shown *before* the system prompt —
"Receipts4Tax needs your camera to scan receipts. Nothing leaves your phone."

## 8. Decide what the share-extension cold start should be — DESIGN QUESTION

Plenty of users will meet this app by sharing a photo from Photos, having never
opened it. That path has no wizard, no priming, no empty state — and it runs the
same `ReceiptSubmitView` with the same validation.

Item 1 fixes it. Items 4–7 do not reach it at all. Worth deciding deliberately
what a first-time share-sheet user should see rather than letting it be whatever
falls out.

## 9. Bundled sample receipt — FIRST RUN ONLY

Let someone tap "Try it" and run the whole pipeline against a receipt image
shipped inside the app. No camera permission, no real receipt in hand. They see
it work in seconds, before being asked for anything.

Lowest priority of the set — nice, not load-bearing.

---

## Explicitly not doing

**No account or cloud fallback.** That is the TaxLens/Expensify model and the
thing this architecture deliberately avoids — no server is why there is no
login, and it is the product's main claim.

**Not loosening OCR accuracy further.** Item 1 solves "can't submit" without
needing better guesses.

---

## Sequencing

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9

Item 1 first: it is the only one with a real bug behind it, it is permanent, and
it is the only one that also covers the share extension.
