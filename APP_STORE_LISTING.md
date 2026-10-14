# App Store Listing — Receipts4Tax

Draft copy for App Store Connect. Not reviewed by counsel. Every claim here was
checked against the code; see the notes at the bottom before changing any of it.

## Name (30 char limit)

```
Receipts4Tax
```

## Subtitle (30 char limit)

```
Private receipt & tax tracker
```
29 characters. Alternatives: `Receipts stay on your iPhone` (28), `Receipt scanner. No account.` (28).

## Keywords (100 char limit)

```
receipt,scanner,expense,tax,deduction,invoice,business,bookkeeping,offline,private,csv,IRS,audit
```
95 characters. Deliberately excludes words already in the app name — those are
indexed from the name itself and would be wasted here. Deliberately excludes
"mileage": competitors advertise it, this app does not do it, and a keyword the
app can't deliver on invites one-star reviews.

## Promotional text (170 char limit, editable without a new build)

```
We never see your receipts — there's no account and no server to send them to.
Scan, extract, and export tax-ready records that stay on your iPhone.
```

## Description (4000 char limit)

```
We never see your receipts. There's no account, and no server to send them to.

Receipts4Tax stores your receipts on your iPhone. DATA TECHNOLOGY GROUP INC.
operates no backend and receives nothing — not your images, not your amounts,
not your vendors.

CAPTURE ANY WAY YOU LIKE
Photograph a receipt, scan it with the document scanner, pick one from your
library, import a PDF, or share one straight from Mail, Messages, or any other
app. Enter details by hand when you'd rather.

AI THAT READS RECEIPTS — AND YOU CHOOSE WHOSE
Connect Claude, OpenAI, Gemini, Perplexity, or Microsoft Document Intelligence
using your own API key. When you do, your receipt is sent to that company and
handled under their privacy terms — we're not in the middle, and we don't proxy
it.

Prefer that nothing leaves at all? Choose Apple On-Device extraction. The
receipt is read by Apple's on-device model, on your iPhone, with no network
involved.

Or use no AI. On-device text recognition fills in what it can and you confirm
the rest.

BUILT FOR TAX TIME
Organize receipts into your own categories. Each one keeps a plain CSV log you
can open in Numbers, Excel, or hand straight to your accountant — no export
step, no proprietary format, no lock-in.

FIND ANYTHING
Search by vendor, amount, date, or category. With an AI connected, ask in plain
English — "restaurants over $100".

DON'T PAY TWICE
Duplicate detection catches the same receipt entered twice, including the
awkward case where one copy includes the tip and one doesn't — and for Zelle,
Venmo, and PayPal screenshots, it checks the payment reference number.

WORKS OFFLINE
Airplane mode, dead zone, no signal — capture and save anyway. Offline Mode
blocks cloud AI entirely if you want a hard guarantee.

YOUR DATA, YOUR CONTROL
Receipt images are stored on your iPhone and excluded from iCloud and device
backups, so a system backup never uploads them. The app's own backup archives
are included, so you can recover after losing a phone. Everything is visible in
the Files app — and anything you copy into iCloud Drive or Photos yourself is
your choice.

No analytics. No tracking. No advertising. No third-party SDKs of any kind.

FREE TO START
Your first 25 receipts are free, with every feature included. After that,
Receipts4Tax Pro unlocks unlimited receipts for $7.99 a year. Receipts you've
already saved stay fully usable either way — browse, search, edit, export,
and back up.

Receipts4Tax Pro is an auto-renewing yearly subscription. Payment is charged to
your Apple Account when you confirm the purchase. It renews automatically
unless cancelled at least 24 hours before the end of the current period, and
you can manage or cancel it anytime in Settings › [your name] › Subscriptions.
Prices may vary by country or region.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://www.dtgincorp.com/privacy

iPhone and iPad.
```
2930 characters.

## Accuracy notes — read before editing

Apple compares the listing, the App Privacy questionnaire, and the privacy
policy against each other. Every claim below is deliberately worded and was
verified in the code.

**"We never see your receipts"** — unconditionally true and safe to lead with.
There is no backend and no analytics SDK of any kind (grepped for Firebase,
Mixpanel, Amplitude, Crashlytics, Sentry — none present). This is a claim about
*us*, which is why it survives regardless of what the user configures.

**Do NOT write "your receipts never leave your phone."** That is false whenever
a cloud provider is configured — the receipt image goes to Anthropic, OpenAI,
Google, Perplexity, or Microsoft. The listing says so explicitly. Stating it
plainly reads as confidence and makes the Apple On-Device sentence that follows
land harder; implying otherwise is an App Review risk.

**Apple On-Device is the only unconditional "nothing leaves" path**, and it is
named as a choice rather than a general property.

**iCloud wording is precise.** `LocalReceiptStore.excludeReceiptsFromBackup()`
marks the receipt folders `isExcludedFromBackup` on every launch, so receipt
images are genuinely skipped by system backups. The sibling `Documents/Backups`
folder is NOT excluded, so archives the app creates do reach iCloud Backup —
that is the deliberate recovery path. And anything the user copies into iCloud
Drive via the Files app is their own doing. All three facts are stated.

**Check a Bill is NOT in this release** (`AppConstants.billItemizationEnabled
= false`), so the listing no longer mentions it. Describing a feature the
binary doesn't have is an App Review 2.3.1 rejection. Restore the section if
and when the flag is turned on.

**Pricing paragraph** — App Review 3.1.2 wants a subscription's name, length,
price, auto-renewal terms, and functional Terms of Use and Privacy Policy links
in the metadata, not only inside the app. Keep the price in step with App
Store Connect if it changes. "Every feature included" is true: the free tier
gates only the number of receipts. Grandfathered (pre-subscription) users are
deliberately not mentioned — it concerns only existing TestFlight testers.

**Payment reference** — the duplicate check reads REF/Transaction ID numbers
off payment-app screenshots (`PaymentReference`), only when a duplicate is
already suspected. Nothing is stored, so no privacy wording changes.

**"CSV you can hand to your accountant"** is a real differentiator worth
keeping — competitors lock data into their own formats.

## Other App Store Connect fields

- **Support URL:** https://www.dtgincorp.com/support
- **Marketing URL (optional):** https://www.dtgincorp.com
- **Privacy Policy URL:** https://www.dtgincorp.com/privacy (live; PRIVACY.md is its text)
- **Copyright:** © 2026 DATA TECHNOLOGY GROUP INC.
- **Category:** Finance (secondary: Productivity)

## App Review notes (App Review Information → Notes)

Paste below, replacing `<KEY>` with a **freshly created** Anthropic key that
has a small spend limit. Revoke it once the app is approved. No sign-in is
needed, so leave "Sign-in required" unticked.

```
Receipts4Tax reads receipt photos with AI and keeps a running, searchable log of business expenses. No account or sign-in is needed.

READING RECEIPTS
On devices with Apple Intelligence the app reads receipts on the device, with no key. If your device lacks Apple Intelligence, please use this temporary Claude API key:
1. Settings > Receipt Extraction > AI Provider: choose Claude.
2. Paste into "Anthropic API Key": <KEY>
3. Back on Receipts, tap + and scan or pick any receipt. With no receipts yet, "Try a Sample Receipt" on the first screen shows the full flow without a camera.

SUBSCRIPTION (Receipts4Tax Pro, $7.99/year, auto-renewing)
The first 25 receipts are free. Adding a 26th opens the paywall. To reach it directly: Settings > Subscription > "Subscribe — Unlimited Receipts". Restore Purchases is in Settings > Subscription and on the paywall, which also links the Terms of Use and Privacy Policy.

Receipt images stay on the device. Only what is sent for reading goes to the AI provider the user picks.
```

## Still to produce

- ☑ Screenshots: generated 2026-10-14 by the `ReceiptDropScreenshots` scheme
  (fictional demo data) → `~/Desktop/Receipts4Tax-App-Store-screenshots/`:
  iPhone 6.9" 1320×2868 and iPad 13" 2064×2752, JPEG, no transparency. Upload
  in order 1-Receipts, 2-Receipt, 3-Search, 4-Insights.
- App preview video (optional)
