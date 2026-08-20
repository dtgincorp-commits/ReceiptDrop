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

CHECK A BILL
Photograph a restaurant bill and get it split line by line, so you can see
exactly what you're being charged for before you pay.

FIND ANYTHING
Search by vendor, amount, date, or category. With an AI connected, ask in plain
English — "restaurants over $100".

DON'T PAY TWICE
Duplicate detection catches the same receipt entered twice, including the
awkward case where one copy includes the tip and one doesn't.

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

iPhone and iPad.
```

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

**"CSV you can hand to your accountant"** is a real differentiator worth
keeping — competitors lock data into their own formats.

## Still to produce

- Screenshots (required for App Store release; not required for TestFlight)
- App preview video (optional)
- Support URL (required) and Marketing URL (optional)
- Privacy Policy URL — see PRIVACY.md, still needs hosting
