# ReceiptDrop — App Store Public Release Checklist

Working plan to take ReceiptDrop (Receipts4Tax) from TestFlight to a
**free-to-download, subscription** App Store app, published under
**DTG (Organization)**.

Tracked in git (first added in `59aed16`); commit updates to it. Companion to `NICKHIL_HANDOFF.md`
(ship pipeline) and `README.md` (identifiers/branches).

**Last updated: 2026-10-14.** Keep this file current — an out-of-date copy
of it once produced a "next steps" list full of finished work.

**Decisions locked:** Free download, first 25 receipts free (lifetime), then
**$7.99/year** auto-renewing subscription (decided 2026-09-29, replacing
paid-once; see SUBSCRIPTION_PLAN.md) · Published under DTG (California corp)
as an Apple Developer **Organization** · India at a hand-set local price ·
China excluded at launch.

**Decisions still open** (flagged inline as ☐ DECIDE):
- Accept "DTG" as public Seller, Nickhil credited in Copyright (see note).
- EU: excluded from the subscription's availability on 2026-09-29 (with
  China). **Bring EU back when:** (1) the D&B address update has reached
  Apple (Business page shows Tustin), (2) DSA status is set to **trader**
  with the correct address, (3) EU re-ticked in BOTH the app's Pricing and
  Availability and the subscription's Availability. No app update needed.
  **China:** only once AI extraction works there, an ICP filing exists, and
  Chinese receipts are tested — a later project, possibly never.

> **Seller name note:** the public "Seller" on an Organization account is DTG's
> legal entity name — an individual's personal name ("Nickhil Nagpal") cannot
> be the seller of a corporate account. Credit Nickhil in the **Copyright**
> field (free text) and the in-app About screen instead.

---

## Where things stand (2026-10-14)

| Area | Status |
|---|---|
| DTG developer account, app record, bundle `com.datatechnologygroup.receipts4tax` | ☑ Done |
| TestFlight external beta (Beta App Review passed 2026-09-01) | ☑ Live — <https://testflight.apple.com/join/wgYgEW8S> |
| Free Apps + Paid Apps Agreements | ☑ **Active** (2026-09-29) |
| Bank account + W-9 | ☑ Active |
| Small Business Program | ⏳ Submitted 2026-09-29, awaiting Apple's email |
| Privacy Policy URL | ☑ <https://www.dtgincorp.com/privacy> |
| App Privacy label | ☑ Published |
| Privacy manifests (app + extension) | ☑ Committed (`156f1a2`, `9d3d17c`) |
| Subscription product in App Store Connect | ☑ Complete 2026-10-07: price, availability, display name, review notes and screenshot |
| Subscription/paywall code | ◐ Uncommitted on `pdf-share-and-backup-fixes`. **Test 1 (Simulator) passed 2026-10-01** and **Test 2 (real sandbox, iPad) passed 2026-10-05**: buy, unlimited after buying, expiry, restore (nothing / active), reinstall. Dark-mode price card fixed. **Committed `39e60c6` 2026-10-05.** |
| App-level Pricing and Availability (Free; no EU, no China) | ◐ Free + EU/China unticked 2026-10-07; confirm the page saved, untick Vision Pro and Mac |
| Age rating | ☑ 4+ (Brazil AL, Korea ALL, Vietnam 00+ — the same "all ages" rating in their own national systems) |
| Screenshots, description | ◐ Screenshots generated 2026-10-14 → `~/Desktop/Receipts4Tax-App-Store-screenshots/` (`ReceiptDropScreenshots` scheme); listing text in `APP_STORE_LISTING.md` (`c781f24`). Upload both |
| Version number | ☑ 1.0.1 (decided 2026-10-05) |
| Build, review notes, submit | ◐ Review notes drafted in `APP_STORE_LISTING.md` (needs a fresh revocable API key); build and submit still to do |

---

## Phase 0 — Account & legal foundation

- ☑ **D-U-N-S number obtained** for DTG.
- ☑ **DTG enrolled** as an Apple Developer **Organization**; the app lives
  under DTG's team (9QPSF3ZB76).
- ☑ **Fresh app record vs. transfer** — resolved: the app is on DTG.
- ☑ **Paid + Free Apps Agreements Active** (2026-09-29). They were stuck on
  "Pending User Info" until two items were completed: **Legal Entity
  Compliance Screening** (Certificate of Incorporation upload, website,
  business affiliation) and **Digital Services Act** trader status.
- ☑ **Tax (W-9) and banking** Active.
- ⏳ **Small Business Program** — enrollment submitted 2026-09-29 (No to all
  associated-account questions). Apple replies by email, typically days to
  ~2 weeks. Not a launch blocker; 15% applies from the next fiscal month
  after approval.
- ☐ **Update DTG's address with Dun & Bradstreet** (dnb.com). Apple's legal
  record and the DSA trader address still show the OLD (Irvine) address; the
  current one is the Tustin address published in PRIVACY.md.
  Apple's forms lock the address to D-U-N-S — it can only change there first,
  then via developer.apple.com/contact → Membership and Account. If
  California's Statement of Information is also stale, update it too.
- ☐ (Optional) Add **Neeraj** to DTG's Developer Program team → enables local
  signing under DTG and retires the `local-dev-dtgincorp` branch split.

## Phase 1 — Listing assets

Owner: **Neeraj (Admin)**. Draft copy is in `APP_STORE_LISTING.md`.

- ☐ **Name, subtitle, promotional text, description** — paste from
  `APP_STORE_LISTING.md`. **Before pasting, add** the price line ("Free for
  your first 25 receipts. Then Receipts4Tax Pro: $7.99/year, auto-renews,
  cancel anytime in Settings.") and links to **Terms of Use**
  (Apple's standard EULA) and the **Privacy Policy** — Apple commonly rejects
  subscription apps without the Terms link.
- ☐ **Keywords** and **category** (Finance).
- ☐ **Copyright:** `© 2026 DATA TECHNOLOGY GROUP INC.`
- ☑ **Screenshots** (2026-10-14, see `APP_STORE_LISTING.md`): iPhone **6.9" (use the iPhone Pro Max simulator for exact
  size) **and iPad 13"** — required because the app is universal
  (`TARGETED_DEVICE_FAMILY: "1,2"`).
- ☑ **App icon** at store resolution (`icon-1024.png`).
- ☐ **Age rating** questionnaire (App Information → Age Rating) — expect 4+.
- ☐ **Support URL:** `https://www.dtgincorp.com/support`.

## Phase 2 — Compliance & privacy

- ☑ **Privacy Policy URL:** <https://www.dtgincorp.com/privacy> — live,
  product-specific, covers AI providers. Also wired into the paywall
  (`AppConstants.privacyPolicyURL`).
- ☑ **App Privacy label** published: Photos or Videos, Other Financial Info,
  Name, Phone Number. Name + Phone come from Check a Bill's contact picker,
  which is hidden in this release — review whether they still belong.
- ☑ **Privacy manifests** declare Photos or Videos + Other Financial Info (app
  functionality, not linked, no tracking), UserDefaults (CA92.1, 1C8F.1) and
  file timestamps (C617.1). Must stay consistent with the label.
- ☑ **Export compliance:** `ITSAppUsesNonExemptEncryption: false`.

## Phase 3 — Production build & submit

- ◐ **Subscription** (App Store Connect → Apps → Receipts4Tax → Monetization →
  Subscriptions), created 2026-09-29:
  - ☑ Group reference name **Receipts4Tax Pro**; subscription reference name
    **Pro Yearly**; product ID **`com.datatechnologygroup.receipts4tax.pro.yearly`**
    (verified against `AppConstants.proYearlyProductID`); Apple ID 6817537442;
    duration **1 year**; status Prepare for Submission.
  - ☑ Availability: all except the **27 EU countries** and **China mainland**
    (132 regions). "Confirm Upfront Billing" accepted (full year charged at
    the start — what the app expects).
  - ☑ "Monthly with a 12-Month Commitment" left **OFF** — the app isn't built
    for it (also needs iOS 26.4+ / SDK 26.5+).
  - ☑ Price: **US $7.99 as the base**, **India ₹399** hand-set.
  - ☑ Review Notes: "Unlocks unlimited receipts after the first 25 free ones.
    The paywall appears when adding a 26th receipt; Restore Purchases is on
    the same screen."
  - ☑ **Display Name and Description entered 2026-10-07** (English U.S.:
    "Receipts4Tax Pro" / "Unlimited receipts, renewed yearly."). Optional
    1024×1024 subscription image skipped — only used for promotions and
    win-back offers. Name was DECIDED 2026-10-05:
    **Receipts4Tax Pro** (no app changes needed). User still to enter it in
    App Store Connect. Description:
    "Unlimited receipts, renewed yearly." Options were:
    `Receipts4Tax Pro` (matches the app today — SettingsView "Receipts4Tax
    Pro", paywall "Pro removes the limit"; recommended), `Receipts4Tax
    Unlimited`, or plain `Receipts4Tax` (the last two need the in-app wording
    changed to match).
  - ☑ **Review screenshot uploaded and accepted 2026-10-02** (Save stays grey
    afterwards: App Store Connect saves the upload itself). Re-captured 2026-10-02 at **1290×2796 JPEG, no
    alpha** (iPhone 15 Pro Max simulator) →
    `~/Desktop/Receipts4Tax-paywall-for-App-Review.jpg` (light mode, $7.99/yr,
    Terms + Privacy links visible). The first capture (1179×2556, iPhone 15
    Pro) was rejected: "The dimensions of one or more screenshots are wrong".
    Re-capture if the paywall changes before release (TmpPaywallShot approach:
    render PaywallView in the test host with SKTestSession). Originally:
    the paywall, from the FINAL build
    (user is still changing the app, so the paywall may change). Either Claude
    captures it in the Simulator, or the user takes it on the phone during
    sandbox testing (side button + volume up).
  - ☐ Billing Grace Period (optional, recommended: 16 days, all renewals).
  - Family Sharing left **OFF** on purpose — it cannot be turned off once on.
  - Do **not** press "Add for Review" on its own: the first subscription must
    be submitted together with a new app version.
- ◐ (2026-10-07: price **Free** confirmed, US base; EU 27 + China mainland
  unticked → 147 regions, awaiting the saved-page check; Mac availability
  off; Vision Pro to untick) **App-level Pricing and Availability** (Monetization → Pricing and
  Availability — separate from the subscription's): price **Free**; untick the
  27 EU countries and China mainland so both lists match.
- ☑ **Age rating set (confirmed 2026-10-11): 4+**; Brazil, Korea and Vietnam
  show their own national labels for the same "all ages" rating. (General → App Information → Age Rating → Edit): "None"/"No"
  throughout → expect **4+**.
- ☐ **Finish + commit the subscription code**, then **sandbox-test on a
  phone**: buy, restore, hitting the 25-receipt wall, grandfathered TestFlight
  users never walled.
- ☐ Phone checks from 2026-09-28: share-sheet auto-close; Extraction Eval
  amount score not worse after the amount-guardrail fix.
- ☑ **Test 2 PASSED 2026-10-05 — real sandbox purchase on the iPad** (the phone is grandfathered
  and can't show the paywall):
  1. ☑ (2026-10-04, account listed; its verification link said "Invalid
     account" when opened while signed into the real Apple ID — harmless
     so far) User: App Store Connect → Users and Access → Sandbox → Test Accounts →
     + (an email that is not an Apple ID, e.g. a "+" alias of the DTG Gmail address,
     country United States).
  2. ☑ (2026-10-04: no prior copy, Developer Mode on, iPad registered in the
     developer account) User: iPad — remove any test copy of Receipts4Tax (ask first if it holds
     real receipts), Developer Mode on (Settings → Privacy & Security), plug
     into the Mac and Trust.
  3. ☑ (2026-10-04: Debug build installed via `devicectl` — launched outside
     Xcode, so purchases hit the real sandbox; Settings → Developer →
     Purchase Testing has "Use Up Free Receipts") Claude: install a build with the scheme's StoreKit configuration
     disabled (real sandbox, not local fake purchases), plus a DEBUG-only way
     to jump to "25 receipts used".
  4. ☐ User: Settings → App Store → Sandbox Account → sign in (may only appear
     after step 3).
  5. ☑ (2026-10-05: expiry → free limit back; Restore with nothing active →
     "No active subscription found"; re-subscribe, delete, reinstall → the
     subscription was recognised on launch and Restore confirmed it.
     Sandbox subscriptions lapse within hours, so re-test Restore right after
     buying.) (2026-10-04: wall hit, sandbox purchase succeeded — iPad data showed
     grandfathered=false, isSubscribed=true, a receipt saved after buying;
     the Sandbox Account setting lives under Settings → Developer on iPadOS 26.
     Restore still to test) User: hit the wall, Subscribe (sheet must say [Sandbox], $7.99/year),
     add receipts freely, delete + reinstall, Restore Purchases.
- ☑ (user confirmed on the phone 2026-10-05; Extraction Eval run still
  pending — user will do it later) Phone checks for app changes made 2026-09-30 → 10-01 (all committed on
  `pdf-share-and-backup-fixes`, each revertable on its own):
  `89d8e58` Looks Good pill + grey lens · `92a731d` Save in Edit toolbar ·
  `aee043a` no-amount receipts can't be confirmed ("No amount" / "Add
  Amount") · `52e58ff` Zelle payee matching + "Not a Duplicate" ·
  `dfcc0f0` duplicates settled by payment reference · `2fedf31` Save in
  Enter Receipt toolbar · `bede3ed` search =, >, <, >=, <=.
- ☑ Fixed `ac827cf` (2026-10-05): totals, Insights and amount search now read
  "$410.00" and "1,591.94"; the real Receipts total was $2,051.94 short.
- Also 2026-10-05: `be044a0` Scanned/Added date on Edit · `e583101` version
  and build shown at the bottom of Settings ("Receipts4Tax 1.0.1 (1)") —
  use it to confirm which build a device runs. Plus the build date on the
  line below (commit after e583101, 2026-10-05).

- ☑ **Version decided 2026-10-05: 1.0.1** (user's choice; keeps TestFlight
  testers out of a new Beta App Review). The build number still has to go
  up for every upload — set it at merge time. Originally: **DECIDE (user): release version number.** User will choose it after
  making a few more app changes — don't pick or bump it until told. Code is
  at 1.0.1 (1); recommendation given was 1.1 (above every TestFlight build;
  costs one quick external Beta App Review). The App Store Connect version
  must match the build's.
- ☐ Merge `pdf-share-and-backup-fixes` → `main`; set version + build number.
- ☐ App Store Connect's version page reads **"1.0 Prepare for Submission"** —
  change its version to **1.0.1** to match the build before attaching it.
- ☐ Pricing and Availability page: "iPhone and iPad Apps on Apple Silicon
  Macs" — recommended OFF for launch (never tested on a Mac).
- ☐ Build via the existing pipeline (fork-sync → Xcode Cloud → App Store
  Connect, per `NICKHIL_HANDOFF.md`) and do a final TestFlight pass.
- ☐ Set the app itself to **Free**; set **availability** (no China; no EU if
  non-trader was chosen).
- ☐ **CRITICAL — review notes:** a **working AI API key** (revocable) plus
  *"Open Settings → API Key, paste this key, then scan any receipt."* — the
  reviewer's device may not have Apple Intelligence. Also mention the
  subscription and how to reach the paywall.
- ☐ Submit with the subscription attached; release type **manual**. Budget for
  **1–2 rejection rounds**.

## Phase 4 — Launch mechanics

- ☑ **Price decided:** $7.99/year after 25 free receipts, to be adjusted from
  the response. A price change needs no app update — the paywall reads
  `Product.displayPrice` live. Lowering reaches existing subscribers
  automatically; when raising, choose **preserve prices for existing
  subscribers** to avoid notices and consent requests.
- ☑ **India:** ₹399/yr, hand-set on the subscription.
- ☐ **China:** unavailable at launch — AI availability, ICP filing, untested
  fapiao receipts (re-check before enabling).
- ☐ Post-launch: watch sign-ups 4–6 weeks, then adjust price; canned support
  reply for *"how do I get an API key?"* (Apple On-Device is the no-key path).

---

## Lessons learned — read before redoing any of this

App Store Connect gotchas hit on 2026-09-29, so they are not rediscovered:

- **"Pending User Info" on the agreements** had nothing to do with bank/tax
  (both Active). It was two hidden tasks: **Legal Entity Compliance
  Screening** (upload Certificate of Incorporation / Articles from
  bizfileonline.sos.ca.gov, website `https://www.dtgincorp.com`, business
  affiliation = your title) and **Digital Services Act** trader status. The
  agreement names aren't links for this; the tasks surfaced as dialogs.
- **DTG's address is locked to the D-U-N-S record** in every Apple form
  (legal entity, DSA). The only fix is updating Dun & Bradstreet first.
- **Small Business Program** is not on developer.apple.com/account. Direct
  link: <https://developer.apple.com/app-store/small-business-program/enroll/>
  (Account Holder only; needs the Paid Apps Agreement Active). Associated
  developer account questions: all No, unless DTG/Neeraj owns or controls
  another *paid* developer account (a free Personal Team doesn't count).
- **Subscription price base country matters.** The first attempt used India
  ₹399 as the base, so Apple converted every other country from it (~$4.99,
  €3.99). Always add the price with **United States $7.99** as the base, then
  override India. Check the dialog's "based on …" line says USD.
- **The price list shows all 175 regions even where the product isn't sold.**
  Availability, not the price list, decides where it's offered.
- **"App Store Localization" is now called "Display Name and Description"**
  on the subscription page.
- **"Monthly with a 12-Month Commitment"** is a separate billing option on the
  subscription page, with its own "Set Up Availability" link — leave it off.
- **Family Sharing is irreversible** once turned on.
- **The first subscription must ship with a new app version** — don't use
  "Add for Review" on the subscription alone.
- **Menu names drift.** When a step here doesn't match the screen, ask for a
  screenshot rather than guessing.

- **Your own phone can't test the paywall**: it is grandfathered (has
  receipts), so the paywall never appears. Use a fresh install on the iPad
  (it shows as "Neeraj's iPhone 8 PLUS (2)") for the sandbox test. Don't
  un-grandfather the phone — that would put real data behind the wall.
- **Running from Xcode uses fake local purchases** (the scheme's
  Products.storekit). For a real sandbox purchase, disable the StoreKit
  configuration in the scheme or install via TestFlight. In sandbox a
  "year" renews in about an hour.
- **Dark mode hid the paywall price**: `Theme.skyBlueLight` is a fixed
  colour; under white dark-mode text the price was near-invisible. Check
  any new fixed-colour background in both modes.
- **Review/App Store screenshots must be a standard App Store size** —
  1179×2556 (iPhone 15 Pro) is rejected and greys out Save. Use the iPhone
  Pro Max simulator (1290×2796), and save as JPEG: PNGs with transparency
  are also commonly rejected.
- **Never edit the built app's Info.plist in a build script** to stamp
  data: on device builds it raced Xcode's own plist write and broke the code
  signature. Generate a Swift source file before compiling instead (see the
  "Generate build date" step in project.yml).
- **Run `SubscriptionPurchaseTests` on the iPhone 15 Pro Max simulator**, not
  the iPhone 17 Pro Max. On the latter (iOS 26.5) the StoreKit test session
  fails to start ("Error saving configuration file"), purchases fall through
  to a real "Sign in to Apple Account" prompt, and the run hangs. Everything
  else runs fine there.
- **App Store screenshots** come from the `ReceiptDropScreenshots` scheme
  (fictional demo data, Simulator-only code). Run it on the iPhone 17 Pro Max
  and iPad Pro 13-inch simulators with `TEST_RUNNER_SCREENSHOT_DIR=<folder>`
  after `xcrun simctl status_bar <id> override --time 9:41 …`, then convert
  to JPEG. See `ReceiptDropUITests/AppStoreScreenshots.swift`.
