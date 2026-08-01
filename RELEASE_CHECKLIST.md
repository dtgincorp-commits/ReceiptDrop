# ReceiptDrop — App Store Public Release Checklist

Working plan to take ReceiptDrop from TestFlight to a **paid**, publicly
downloadable App Store app, published under **DTG (Organization)**.

Local-only planning doc (not committed). Companion to `NICKHIL_HANDOFF.md`
(ship pipeline) and `README.md` (identifiers/branches).

**Decisions locked:** Paid-once · Published under DTG (California corp) as an
Apple Developer **Organization**.

**Decisions still open** (flagged inline as ☐ DECIDE):
- App transfer vs. fresh app record under DTG (see Phase 0).
- Price tier (see Phase 4).
- Accept "DTG" as public Seller, Nickhil credited in Copyright (see note).

> **Seller name note:** the public "Seller" on an Organization account is DTG's
> legal entity name — an individual's personal name ("Nickhil Nagpal") cannot
> be the seller of a corporate account. Credit Nickhil in the **Copyright**
> field (free text) and the in-app About screen instead.

---

## Phase 0 — Account & legal foundation (LONG POLE — start immediately)

Owner: **Nickhil / DTG principal** unless noted.

- ☑ **D-U-N-S number obtained** for DTG (received via email). Long pole cleared.
- ☐ Before enrolling, confirm DTG's **legal name + address on the D-U-N-S
  record exactly match** the CA incorporation details — Apple cross-checks them,
  and a mismatch is the most common enrollment stall.
- ☐ Enroll **DTG** in the Apple Developer Program as an **Organization**
  ($99/yr) at developer.apple.com/enroll → Company/Organization → enter the
  D-U-N-S number. Confirm **authority to bind DTG** (Apple may email/call to
  verify).
- ☐ **DECIDE:** move the existing app to DTG by **app transfer** (keeps bundle
  ID + history; has prerequisites) **or** create a **fresh app record** under
  DTG (simpler pre-launch; re-add TestFlight testers — no public installs to
  lose). Recommended: fresh record unless history matters.
- ☐ **Account Holder** accepts the **Paid Applications Agreement** in App Store
  Connect → Business. *Only the Account Holder can accept it — an Admin cannot.*
  Nothing sells until this shows **Active**.
- ☐ Enter **tax forms** (W-9 for a US corp) and **banking** for DTG (Admin can
  enter; agreement must be accepted first).
- ☐ **Apply to the Apple Small Business Program** (15% commission instead of
  30%; DTG qualifies while under $1M/yr). Easy to forget — do it.
- ☐ (Optional but recommended) Add **Neeraj** to DTG's Developer Program team →
  enables local signing under DTG and lets you **retire the `local-dev-dtgincorp`
  branch split** (see README "Retiring the split").

## Phase 1 — Listing assets

Owner: **Neeraj (Admin)** can do all of this.

- ☐ App **name** (confirm availability), **subtitle**, **promotional text**,
  **description**.
- ☐ **Keywords** and **primary/secondary category** (Finance or Productivity).
- ☐ **Copyright** field (e.g. `© 2026 Nickhil Nagpal / DTG`).
- ☐ **Screenshots** for each required device class (Apple's largest iPhone size
  at minimum; iPad set if the app runs on iPad).
- ☐ **App icon** at store resolution.
- ☐ **Age rating** questionnaire.
- ☐ **Support URL** (mandatory) and **Marketing URL** (optional).

## Phase 2 — Compliance & privacy

Owner: **Neeraj (Admin)**.

- ☐ **Privacy Policy URL** (mandatory). Must disclose that receipt data is
  transmitted to the selected AI provider (Anthropic / OpenAI / Google) for
  processing when a cloud provider is used.
- ☐ **App Privacy "nutrition label":** declare **User Content** and **Financial
  Info** are transmitted to a third party (yes — even though the app is
  local-first, sending to the AI provider counts as data leaving the device).
  Confirm **no tracking / no IDFA** (keeps the label clean — a selling point).
- ☐ **Export compliance:** answer the encryption question (standard OS HTTPS
  typically qualifies for the exemption, but you must answer).

## Phase 3 — Production build & submit

Owner: **Nickhil** (build), **Neeraj** (metadata).

- ☐ Bump **marketing version** + **build number**.
- ☐ Build a release via the existing pipeline (fork-sync → Xcode Cloud → App
  Store Connect, per `NICKHIL_HANDOFF.md`). If moved to DTG, re-point signing/
  Xcode Cloud to DTG's team first.
- ☐ **CRITICAL — review notes:** paste a **working AI API key** (a throwaway
  you can revoke after approval) plus: *"Open Settings → API Key, paste this
  key, then scan any receipt."* Without this the reviewer cannot use the app →
  near-certain **Guideline 2.1** rejection.
- ☐ Set **pricing / paid tier** (see Phase 4).
- ☐ Submit for review. Budget for **1–2 rejection rounds** — BYO-key apps
  sometimes draw follow-up questions about the third-party data flow.

## Phase 4 — Launch mechanics

Owner: **Neeraj / Nickhil**.

- ☐ **DECIDE: price tier** — what does DTG want to charge?
- ☐ Release type: **manual** (recommended for a first launch — you control the
  go-live moment), automatic, or phased rollout.
- ☐ Post-launch: crash monitoring; a canned support reply for the inevitable
  *"how do I get an API key?"* (point non-technical users to Apple On-Device on
  capable iPhones as the no-key path).

---

## Critical-path summary

1. **D-U-N-S → DTG Org enrollment → Paid Apps Agreement** is the long pole.
   Start it before anything else; the rest can proceed in parallel once the
   account exists.
2. **Reviewer API key in the review notes** is the one step that most commonly
   sinks a BYO-key app. Don't skip it.
3. Everything in Phases 1–2 (Neeraj, Admin) can be prepared *while* the DTG
   account is being set up.
