# Collaborative workflow: Neeraj ↔ Nickhil

Goal: **both of us work on our own branch on the shared repo**, pull from
each other's branch whenever reasonable, merge into `main` when a version is
good, then get `main` onto Nickhil's fork to build/test on TestFlight.

**Status as of 2026-08-01: set up and live.** `neeraj-dev` and `nickhil-dev`
both exist on the shared repo, both currently equal to `main` (`330ef7b`,
which includes Nickhil's PR #2 — on-device extraction overhaul + Spending
Insights). `local-dev-dtgincorp` has been rebuilt on top of the same `main`.

## The model

- **Shared repo** = `github.com/dtgincorp-commits/ReceiptDrop` — the single
  source of truth. All real work lives here.
- **`neeraj-dev`** — Neeraj's working branch. Push freely; Nickhil pulls
  whenever reasonable. Uses the standard `com.nicknagpal.*` identifiers (same
  as `main`) so it can merge cleanly — **not** the same thing as
  `local-dev-dtgincorp` (see identifier rule below).
- **`nickhil-dev`** — Nickhil's working branch, same idea, mirror image.
  Already created (from `main`, so it includes his Jul 30 work) and pushed —
  he just needs `git fetch origin && git checkout nickhil-dev` to pick up
  where he left off. **He does not need to create it himself.**
- **`main`** — stable, shippable. Both branches merge here via PR once a
  version is good.
- **Nickhil's fork** (`nickhilnagpal23-dev/ReceiptDrop`) — only ever receives
  `main`, only for the purpose of an Xcode Cloud build → TestFlight. Nobody
  commits to it directly.
- **`local-dev-dtgincorp`** — Neeraj's **local-only** branch, never pushed.
  Exists purely so Neeraj can build a working copy over USB under a free
  Personal Team (which can't use App Groups under the real `com.nicknagpal.*`
  identity). See the identifier rule below — this is the one branch with a
  different app identity, and it must never leave this Mac.

---

## How the branches flow

```
                    Nickhil's fork (nickhilnagpal23-dev/ReceiptDrop)
                          ↑ ONLY receives main, for Xcode Cloud builds
                          |
                         main  ←──────────────┐  (com.nicknagpal.* — the ONLY
                    (shared repo, stable)      |   identifiers that ever reach
                       ↑        ↑              |   this branch, ever)
                  PR   |        |  PR          |
                       |        |              |
                neeraj-dev   nickhil-dev        |
              (your work)   (his work)          |
                    ↑              ↑            |
        (either of you can pull    |            |
         the other's branch        |            |
         any time to review or     |            |
         build on top of it)       |            |
                                                 |
        local-dev-dtgincorp (LOCAL ONLY, never pushed) ─┘
        = main + one commit that swaps to com.dtgincorp.*
          for Neeraj's wired Personal-Team builds on this Mac.
          Rebuilt from scratch (reset to main, re-apply the one
          commit) every time main moves, rather than merged
          forward — so there is no path for it to drift or leak.
```

---

## Identifier rule — read this before touching branches

**`com.dtgincorp.*` bundle IDs / App Group / entitlements exist in exactly
one place: the tip of `local-dev-dtgincorp`, in one commit.** That branch is
never pushed to the shared repo and never merged anywhere. Nothing else in
this workflow — `neeraj-dev`, `nickhil-dev`, `main`, or Nickhil's fork — may
ever contain `com.dtgincorp.*` identifiers, entitlements, or App Group IDs.

**If `local-dev-dtgincorp` is ever pushed upstream for any reason (it
shouldn't need to be), the identifiers must be switched back to
`com.nicknagpal.*` first.** In practice this means: don't push that branch at
all. If you ever need to bring a *code change* made on that branch into the
shared workflow, cherry-pick the individual feature commit(s) onto
`neeraj-dev` — never the branch itself, and never the identifier-flip commit.

**Before merging anything into `main`, sanity-check:**
```sh
git diff main..<branch> -- '*.pbxproj' '*.yml' '*.entitlements' Shared/AppConstants.swift \
  | grep -iE 'dtgincorp|DEVELOPMENT_TEAM'
```
Empty output = clean. This is the same check already used before every push
to `main` per `README.md`'s hard rules — it now also covers `neeraj-dev` →
`main` and `nickhil-dev` → `main` merges, not just direct pushes.

**Also check `project.pbxproj`'s Xcode format before merging.** Nickhil's
Xcode writes newer-format project files than Neeraj's Xcode 15.2 can open —
his PR #2 (2026-08-01) carried `objectVersion = 63`, which made Xcode 15.2
fail with "Failed to load container for document" the moment Neeraj tried to
open the project, even though it built fine from the command line. Check:
```sh
grep "objectVersion" ReceiptDrop.xcodeproj/project.pbxproj
```
If it's not `56`, run `./generate.sh` — it regenerates the project from
`project.yml` and re-patches the format back to Xcode-15-compatible. Safe to
run any time; it doesn't touch identifiers (whatever's in `project.yml` on the
current branch is preserved), but it does reset the signing team in Xcode —
re-pick your Personal Team under Signing & Capabilities on both targets
afterward. **Nickhil should ideally run `./generate.sh` himself before
committing pbxproj changes**, so this doesn't recur on every pull.

**Rebuilding `local-dev-dtgincorp` after `main` moves** (do this any time you
pull new work into `main` and want a fresh local wired-build copy):
```sh
git checkout -B local-dev-dtgincorp main
git cherry-pick e6848d6   # the one identifier-flip commit
```
This resets the branch clean each time rather than letting it accumulate its
own history — the approach used on 2026-08-01 after merging Nickhil's PR #2.

---

## Daily workflow

### Working on your own branch

```sh
git checkout neeraj-dev     # or nickhil-dev
# ...commit as usual...
git push                    # push whenever, push often
```

### Pulling the other person's branch

```sh
git fetch origin
git checkout nickhil-dev && git pull      # Neeraj pulling Nickhil's work
# or, from Nickhil's side (once he's set up `shared` or uses origin directly
# now that he has collaborator access):
git fetch origin
git checkout neeraj-dev && git pull       # Nickhil pulling Neeraj's work
```

To just look at what changed without switching branches:
```sh
git fetch origin
git diff main..origin/nickhil-dev
git log main..origin/nickhil-dev
```

### Building on top of each other's work mid-stream

```sh
git checkout neeraj-dev
git merge origin/nickhil-dev      # or: git rebase origin/nickhil-dev
```

### Promoting stable work to `main` → ships

Open a **Pull Request** on the shared repo: `neeraj-dev` → `main` (or
`nickhil-dev` → `main`). Run the identifier check above before merging.
Review, merge. Then the normal ship routine runs (`NICKHIL_HANDOFF.md`):
Nickhil syncs his fork from `main`, Xcode Cloud builds, add to TestFlight.

---

## One-time setup (for reference — already done as of 2026-08-01)

1. Neeraj added Nickhil as a **collaborator (Write access)** on the shared
   repo: Settings → Collaborators and teams → Add people.
2. `neeraj-dev` created off `main`, pushed.
3. Nickhil's Jul 30 work merged into `main` via PR #2 (he'd already built on
   his fork before this workflow existed — one-off, not the normal path
   going forward).
4. `nickhil-dev` created off the post-merge `main`, pushed — Nickhil picks it
   up with `git fetch origin && git checkout nickhil-dev`.
5. `local-dev-dtgincorp` rebuilt clean on top of the post-merge `main`.

## Rules that keep this clean

1. **All work goes to `neeraj-dev` or `nickhil-dev`** — never straight to
   `main`, never to the fork.
2. **The fork only ever receives `main`**, only to trigger a build. It's
   never a place code is authored.
3. **`com.dtgincorp.*` identifiers live only on `local-dev-dtgincorp`, which
   is never pushed.** Run the identifier check before every merge into
   `main`.

## Optional future simplification

If Nickhil points **Xcode Cloud's Primary Repository at the shared repo**
directly (he now has access) instead of his fork, the fork and the whole
fork-sync step disappear — one repo, one `main`, build straight from it.
Worth doing once this branch workflow feels comfortable.
