---
name: ios-design-review
description: Review this app's SwiftUI screens for visual design, interaction, hierarchy, and accessibility, and propose concrete improvements. Use when asked to review, critique, or improve the UI/UX/look/feel of a screen or the app, when asked "how does this screen look", "make this nicer", "is this confusing", "design feedback", or when a user reports a screen as confusing, cluttered, or hard to use. Also use before shipping a screen to TestFlight or the App Store.
---

# iOS design review — Receipts4Tax

Review SwiftUI screens against this app's own conventions, then propose
specific changes. Not generic design advice: a finding must name a file, a
line, and the replacement code.

## The standard this app is held to

This is a **tax record keeper**. Two consequences that outrank aesthetics
and should shape every finding:

1. **A wrong value stored silently is the worst outcome.** Worse than an
   ugly screen, worse than an extra tap. Anything that lets bad data through
   without the user noticing is a design bug, not a polish item.
2. **Never block the save.** See TODO.md item 1. A user who cannot save a
   receipt leaves. A save with a flag beats a wall.

## Step 1 — Look at the real thing, not just the code

Static reading misses the failures that matter here. Where practical:

- Build and run in the simulator (see the `run` skill if present), navigate
  to the screen, and capture it:
  `xcrun simctl io booted screenshot /tmp/screen.png`, then read the image.
- Capture **three states minimum**: empty, populated, and error/flagged.
  Most of this app's real bugs have lived in the second and third.
- Check both **light and dark**. The user runs dark; screenshots in this
  repo's history are all dark, so light mode is the under-tested one.
- Check **Dynamic Type at large sizes** and this app's own `AppTextSize`
  small/large settings. `AppTextSize` exists precisely because density
  matters here; a layout that only works at the default size is broken.

If you cannot run the app, say so explicitly in the review rather than
implying the findings are screenshot-verified.

## Step 2 — The design system as it actually is

Use what exists. Do not introduce a new colour, font, or spacing scale
without saying why the existing one fails.

- **Colour** lives in `ReceiptDrop/Theme.swift` and nowhere else.
  `Theme.actionBlue` is reserved for **the one primary action on a screen**
  — proposing a second `actionBlue` control on the same screen is a finding
  against yourself. `Theme.skyBlue` is for ordinary accents,
  `Theme.skyBlueBright` for small high-contrast badges. Semantic colours
  (`.red`, `.orange`, `.green`, `.secondary`) carry meaning already
  established in the codebase: red = error/destructive, orange = needs
  review, green = verified. Do not repurpose them.
- **Type** is semantic (`.caption`, `.subheadline`, `.body`, `.headline`)
  so iOS Dynamic Type and `AppTextSize` both work for free. A hardcoded
  `.font(.system(size:))` is a finding unless justified.
- **Density** scales via `rowInsetScale` in `ReceiptsView`. Fixed padding
  that ignores it caps how much the small text size can actually buy — that
  exact bug is documented in `ReceiptsView`'s list-row comments.

## Step 3 — Run the checklist

Work through these in order. Stop and note anything that fails.

### Affordance and hierarchy
- **Is the primary action unmistakably primary?** One `.borderedProminent`
  per decision. Everything else `.bordered` or plain.
- **Is any escape hatch styled as text?** A caption the user must find in
  order to leave a screen is a trap. Real bug, fixed in `c053b2e`: the
  `.needsDate` prompt's only exit was `.font(.caption)` while the toolbar's
  Cancel sat disabled, and the user reported feeling stuck.
- **Does every disabled control say why it is disabled?** A dead button
  with no explanation is the failure TODO.md item 1 exists to prevent. See
  `blockedSubmitReason` in `ReceiptSubmitView` for the established pattern.

### Information the user must not miss
- Is a flagged/needs-review state visible **without scrolling**?
- Does a warning say what to *do*, not just that something is wrong?
  "Date is over a year old" versus "Date 1969-01-30 is 57 years old — that
  isn't a purchase date, so it was ignored and defaulted to today". The
  second is the standard; see `b711974`.
- Is a destructive action (delete, discard) clearly separated from a
  benign one, and confirmed?

### Layout robustness
- **The share extension is a short, height-constrained sheet.** Anything at
  the bottom of a `Form` can be clipped in half there. This is why Submit
  lives in the toolbar — see the comment in `ReceiptSubmitView.body`. Any
  new bottom-anchored control is suspect.
- Long vendor names, four-figure amounts, and long category names must not
  truncate the number. Test with a receipt like "Santorini White Polished
  Marble Tile" at $3,360.33.
- Does it survive rotation and iPad width, if supported?

### Accessibility — currently this app's weakest area
`ReceiptsView` and `SettingsView` carry labels; the other 24 view files
have none. Treat this as a standing finding until it changes, and re-check
the count rather than trusting this line — it has already gone stale once.
- Icon-only buttons **must** have `accessibilityLabel`. The magnifier,
  trash, and thumbnail buttons in receipt rows currently do not.
- Minimum 44pt tap targets, except deliberate full-width list rows.
- Colour must never be the only signal — the orange "needs review" state
  needs its icon or text, not just the hue.
- Check contrast in **both** schemes; `skyBlueLight` on white is the
  likeliest failure.

### Consistency
- Does this screen's phrasing match the rest of the app? The app says
  "Receipt Date", not "Work Date", in UI (TODO item 2) — `workDate` is a
  storage name only.
- Same control for the same job across screens.

## Step 4 — Report

Order findings by **user cost**, not by ease of fixing. For each:

1. **What** — one sentence naming the defect.
2. **Where** — `file.swift:line`.
3. **Why it costs the user** — concretely. "A first-time tester cannot tell
   the receipt saved", not "reduces clarity".
4. **The fix** — actual SwiftUI, matching surrounding style.

Then a short **"worth considering"** section for genuine alternatives —
different layouts, patterns from Apple's own apps, ideas that are a matter
of taste rather than defect. Keep these clearly separated from findings, and
say which you would pick and why.

Do not pad. Three real findings beat fifteen restatements of the HIG. If a
screen is good, say it is good and say what makes it work, so the pattern
gets reused.

## What not to do

- Do not propose a redesign of a screen that works. This app ships to real
  users on TestFlight; churn has a cost.
- Do not add a dependency or a design library.
- Do not change stored data, CSV columns, or model field names for cosmetic
  reasons — `AppConstants.sheetHeader` is a tax export.
- Do not implement changes unless asked. Review first, then offer.
