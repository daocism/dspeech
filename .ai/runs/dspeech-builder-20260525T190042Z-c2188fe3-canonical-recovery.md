# Canonical recovery / reconciliation note — run `dspeech-builder-20260525T190042Z-c2188fe3`

Role: engineer-backend (ubuntu-vm, mac24 Claude logged out)
Date: 2026-05-25
Branch: `feat/local-pilot-voice-filter`

## Why this note exists

The task brief listed two researcher artifacts as inputs:

- `.ai/runs/dspeech-builder-20260525T190042Z-c2188fe3-researcher-web.md`
- `.ai/runs/dspeech-builder-20260525T190042Z-c2188fe3-canonical-recovery.md` (this path)

**Neither file existed in the worktree** at start of this run. The brief also told
me to preserve any canonical dirty/index changes before discarding them and to
record stale staged-rollback state here. This note records what was actually found
so the chain is auditable.

## Observed git state (worktree `wt-engineer-backend`)

- Started in **detached HEAD** at `a8a643d`, **working tree clean** — no dirty files,
  no staged changes, no stash. There was no canonical dirty state to preserve and
  no staged rollback to unstage; the premise in the brief did not match reality.
- `feat/local-pilot-voice-filter` (checked out in a sibling worktree) was at
  `a8a643d`, marked `behind 1` at fetch time against a stale remote-tracking ref.
- After `git fetch origin`: `origin/feat/local-pilot-voice-filter` had advanced to
  **`4fe4a44`**, well ahead of the CEO-observed head `0331e9b`.

## Topology decision (no `git reset --hard` used)

```
git merge-base --is-ancestor a8a643d origin/feat/local-pilot-voice-filter  → TRUE
git log origin/feat/local-pilot-voice-filter..a8a643d                       → (empty)
```

`a8a643d` is a **strict ancestor** of `origin/feat/local-pilot-voice-filter`
(`4fe4a44`) with **zero local commits ahead**. Origin is a clean fast-forwardable
**superset** of everything local. The 8 commits origin carries beyond `a8a643d`:

```
4fe4a44 docs(ai): record voice-filter end-to-end functional run
1375e09 feat(voice-filter): working model-pack download and pilot enrollment
2b64b71 fix(voice-filter): use real FluidAudio embedding API and offline load
d3b2180 build(deps): pin FluidAudio 0.14.7 (Package.resolved)
3521cc1 feat(voice-filter): dictate aircraft callsign on-device
819cb4a fix(audio): enable Start when a usable mic is available before activation
1d8ce83 refactor(asr): make live recognition callback Swift 6 Sendable-safe
0331e9b feat(voice-filter): offline FluidAudio speaker adapter behind model-pack gate
```

`0331e9b` is the FluidAudio adapter slice the CEO observed; `2b64b71` is the
real-API / offline-load fix that researcher-web would have flagged — it is already
landed on origin. No reconciliation surgery, cherry-pick, or rollback was needed:
I checked out the canonical tip `4fe4a44` (non-destructive, clean tree) and worked
forward from it.

## What this run changed

Doc-only. Origin's FluidAudio adapter code already satisfies the accepted slice
behavior (verified by reading the source — see the dated run note); no code fix was
warranted, so none was invented. Changes:

- `docs/ai-kb/current-context.md` — corrected the stale claim that the only
  `LocalSpeakerIdentifier` conformer is `UnavailableLocalSpeakerIdentifier`, and
  reframed next-priority #1 from "replace it" to "harden the landed adapter".
- `docs/run-notes/2026-05-25-fluid-audio-reconciliation.md` — new dated run note.
- `.ai/project-state.md` — concise reconciliation entry.

Known stale doc left intact on purpose: `docs/eval/local-speaker-model-pack-validation.md`
(dated `Status: Plan`, 2026-05-24) still says "the only adapter on this branch is
`UnavailableLocalSpeakerIdentifier`". It is a dated historical plan snapshot whose
flight-safety disclaimer is still correct; rewriting it would be an unrelated edit
to a dated artifact. Flagged here for the next docs-writer cycle.
