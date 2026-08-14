# App-wide text size setting (Small / Medium / Large)

## In plain English

Add a Settings control letting the user pick how big text is throughout the
app, so people who want more rows on screen can shrink it and people who want
readability can keep it large.

## Comments before building this — read first

**iOS already does this, and the app already supports it.** Settings →
Display & Brightness → Text Size (and Accessibility → Larger Text) changes
text size system-wide, and because this app overwhelmingly uses *semantic*
fonts (49 × `.caption`, 38 × `.subheadline`, 20 × `.caption2`, 7 × `.body`,
plus `.title2`/`.headline`), all of that **already scales today**. A user can
make ReceiptDrop bigger or smaller right now without any change from us.

So this feature is not "make text scalable" — that works. It's **per-app
control**: let someone shrink ReceiptDrop without shrinking Messages, and
make it discoverable to users who don't know iOS's setting exists. That's a
legitimate reason to build it; it's just a smaller reason than it first
appears, and it changes what the right implementation is.

**The accessibility trap — this is the important one.** Setting an exact
`dynamicTypeSize` *overrides* the user's system setting. If someone with low
vision has set Larger Text system-wide and we ship a default of "Medium",
we'd shrink text on the exact person who needs it most. Therefore:

- The default **must** be "System" (follow iOS, override nothing).
- Existing users must land on "System" with no visible change.
- The UI must say plainly that picking a size overrides the iOS setting.

## What already exists (don't duplicate it)

`BillReviewView` has its own local text scaler — `@State textScale`, +/−
buttons, applied to 19 fixed-size `.system(size: N * textScale)` fonts. It is
screen-local, resets each time, and deliberately opts out of Dynamic Type
because that screen exists to be read against a paper bill.

**Leave it alone.** It serves a different purpose, and converting it would
lose a control that makes sense there. Accept that Bill Breakdown won't
respond to the new global setting; note it in the Settings footer if it seems
worth mentioning.

---

## Step 1 — The setting

**File:** `Shared/ReceiptModels.swift` (near `ExtractionSettings` /
`BackupSettings`)

```swift
enum AppTextSize: String, CaseIterable, Identifiable {
    case system, small, medium, large
    var id: String { rawValue }
    var displayName: String { ... }   // "System", "Small", "Medium", "Large"

    /// nil = follow the system setting, overriding nothing.
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .small:  return .small
        case .medium: return .large     // iOS default is .large
        case .large:  return .xxLarge
        }
    }
}
```

Note the mapping: **iOS's own default is `.large`**, not `.medium`. Naming
"Medium" → `.large` keeps our label meaning "normal" while matching what the
OS considers standard. Don't map "Medium" → `.medium` or the app will look
subtly smaller than every other app for someone who picks it.

Store it in the App Group `UserDefaults` alongside the other settings, with a
new key in `AppConstants.DefaultsKeys`. **Default `.system`** — a missing key
must resolve to `.system` so every existing install is unaffected.

`DynamicTypeSize` is SwiftUI, so if `ReceiptModels.swift` doesn't already
`import SwiftUI`, put this type in its own small file rather than adding that
import to a file the share extension compiles.

## Step 2 — Apply it once, at the root

**File:** `ReceiptDrop/ContentView.swift` — the `TabView`

```swift
.dynamicTypeSize(selectedTextSize.dynamicTypeSize ?? .large)
```

Only apply the modifier when the setting is **not** `.system`; when it is,
apply nothing at all so iOS's value flows through untouched. A conditional
`if` around a `.modifier` or an `@ViewBuilder` wrapper is fine.

This must be read as `@State` (or `@AppStorage`) that updates live, so
changing it in Settings redraws immediately rather than requiring a relaunch.

**Sheets and full-screen covers do not inherit the environment from the
presenting view in all cases** — verify that Edit Receipt, the submit screen,
and Connect AI actually change size, and if they don't, apply the same
modifier at those roots too.

## Step 3 — Settings UI

**File:** `ReceiptDrop/SettingsView.swift`

A `Picker` with `.pickerStyle(.segmented)`, in its own Section:

```
Text Size    [ System | Small | Medium | Large ]
```

Footer copy must be honest about the override:

> Changes text size in this app only. "System" follows your iPhone's Text
> Size setting (Settings → Display & Brightness). Choosing a specific size
> overrides it — including any accessibility text size you've set.

## Step 4 — Fixed-size fonts that will NOT scale

Four fonts outside Bill Breakdown are hardcoded and won't respond:

- `ContentView.swift:328` — `.system(size: 44)` (empty-state icon)
- `ReceiptsView.swift:299` — `.system(size: 22, …)` (total amount)
- `ReceiptsView.swift:1157` — `.system(size: 10, weight: .black)` (category/DUP badges)
- `ReceiptsView.swift:1294` — `.system(size: 44)` (empty-state icon)

The two `size: 44` ones are **icons**, not text — leave them; icons scaling
with text size is not expected behavior.

The other two are judgement calls, and I'd leave both alone rather than
convert them blindly: line 299's `22pt rounded bold` is the deliberate
large-total styling on the Receipts header, and line 1157's `10pt black` is
sized to fit inside a small badge pill — making it scale risks the badge
clipping or wrapping. If you want them scalable, use
`.font(.system(size: N, …))` combined with `@ScaledMetric`, not a plain
semantic swap.

## Step 5 — Test at the extremes (this is where it breaks)

Set the app to **Large** and check for clipped or overlapping layout in at
least these places, which have fixed frames or tight rows:

- Receipts list rows — category badge + DUP badge + vendor + amount on one line
- The submit screen's manual-entry fields
- Edit Receipt's photo thumbnail area (`.frame(maxHeight: 180)`)
- Duplicate review rows (`.frame(width: 48, height: 48)` thumbnails)
- Settings' segmented pickers (long provider names already crowd these)

Then set **Small** and confirm nothing became unreadably tiny or lost its tap
target (buttons should stay ≥44pt).

Also verify: with the setting on **System**, changing iOS's Text Size still
affects the app exactly as it does today. That's the regression that matters
most.

## Do NOT do these

- **Don't** default to anything other than `.system`. Overriding an
  accessibility setting for existing users is the one genuinely harmful
  outcome here.
- **Don't** touch `BillReviewView`'s existing `textScale` or its 19
  fixed-size fonts.
- **Don't** convert the four fixed-size fonts in Step 4 without deciding
  case-by-case; two are icons and one is inside a fixed-size badge.
- **Don't** add `import SwiftUI` to a `Shared/` file the share extension
  compiles just to hold `DynamicTypeSize` — put the type somewhere the
  extension doesn't need.
- **Don't** claim in the footer that this is "accessibility" — it overrides
  accessibility settings, which is the opposite.

## Testing note

There are no unit tests to add here — this is presentation only. Verification
is visual, at the extremes, per Step 5. Say plainly which screens were
actually checked rather than implying the whole app was.
