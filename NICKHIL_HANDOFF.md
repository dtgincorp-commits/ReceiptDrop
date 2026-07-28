# Handoff: Neeraj → Nickhil workflow

For any agent (or human) helping Nickhil pull, build, or ship this app. This
file is tracked and committed — it travels to `nickhilnagpal23-dev/ReceiptDrop`
every time the fork is synced, so it should always be current from Nickhil's
side. See `README.md` for full project/identifier documentation; this file is
just the workflow on top of it.

## The pipeline, in one picture

```
dtgincorp-commits/ReceiptDrop (main)   <- Neeraj develops and pushes here
        |
        |  fork sync — MANUAL, does not happen automatically
        v
nickhilnagpal23-dev/ReceiptDrop (main)  <- Nickhil's fork; Xcode Cloud's
        |                                  Primary Repository points HERE,
        |  Xcode Cloud watches this        not at the shared repo above
        v
Xcode Cloud build (cloud-managed signing, com.nicknagpal.* identifiers)
        v
App Store Connect -> manually add to TestFlight testers group -> testers
```

**The one fact that matters most:** a push to the shared repo's `main` is
*invisible* to Xcode Cloud until someone syncs Nickhil's fork. This was the
root cause of Xcode Cloud repeatedly building stale commits (discovered
2026-07-27) — not a signing problem, not a repo problem, just an un-synced
fork.

## Routine: getting a new push live on TestFlight

1. **Sync the fork** (do this every time, even if "probably already synced" —
   it's free to check):
   - Web: `github.com/nickhilnagpal23-dev/ReceiptDrop` → **Sync fork** →
     **Update branch**. No terminal needed.
   - Git: from Nickhil's local clone (`origin` is his fork; add the shared
     repo once as `upstream`):
     ```sh
     git remote add upstream https://github.com/dtgincorp-commits/ReceiptDrop.git   # one-time only
     git fetch upstream
     git merge upstream/main
     git push origin main
     ```
2. **Verify the sync actually took** — don't assume:
   ```sh
   git fetch origin
   git log -1 origin/main
   ```
   Compare the commit hash/message against what Neeraj said he pushed. If it
   doesn't match, the sync didn't work — redo step 1 before touching Xcode
   Cloud.
3. **App Store Connect → ReceiptDrop4545 → Xcode Cloud → Builds** → select one
   specific **workflow** (not "All Workflows" — "Start Build" stays greyed out
   otherwise) → **Start Build**.
4. Wait for the build to succeed, then **manually add it to the TestFlight
   internal testers group**. This is a real extra click — "Enable automatic
   distribution" on the group does not skip it, per Apple's documented
   behavior.

## Identifiers (context, not something to change)

Everything Xcode Cloud builds uses `com.nicknagpal.*` bundle IDs and
`group.com.nicknagpal.receiptdrop` — cloud-managed signing under Nickhil's
paid Apple Developer Program team. Neeraj also has a second, local-only branch
(`local-dev-dtgincorp`) with different identifiers for building unsigned dev
copies on his own Mac under a free Personal Team — that branch is never pushed
anywhere and is irrelevant to this pipeline. Full detail in `README.md` under
"Key identifiers."

## If a build looks wrong or stale

Check, in this order:
1. Did the fork actually get synced? (`git log -1 origin/main` after a fresh
   `git fetch origin`, from Nickhil's clone.)
2. Does Xcode Cloud's build log show the commit hash you expect? (Build detail
   page in App Store Connect shows the commit it built from.)
3. Only then look at signing/entitlements — those have been stable and are
   very unlikely to be the actual cause if a build looks stale.

## Apple account structure (for context, not action needed routinely)

Neeraj has **Admin in App Store Connect** (Users and Access) on Nickhil's
account — that's a different system from **Apple Developer Program team
membership**, which Neeraj does not currently have. This is why Neeraj can't
sign or build locally against `com.nicknagpal.*`, and why this whole
fork-based pipeline exists as the way for his work to reach TestFlight. If
Nickhil's enrollment turns out to be an **Organization** (check
developer.apple.com/account → Membership details), adding Neeraj to the actual
Program team (not just App Store Connect) would let him build/sign directly
and simplify a lot of this — see `README.md`'s "Retiring the split" section.
If it's an **Individual** enrollment, that option isn't available and this
fork-sync workflow is the durable path.
