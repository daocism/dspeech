# Dspeech supervisor — final report

Run ID: `dspeech-supervisor-20260523T132443Z-1c576edf`
Reporter: `qa-manual` (acting as final supervisor reporter per dispatch brief)
Host: `ubuntu-vm`
Canonical repo: `/home/user/projects/dspeech`
Branch: `feat/local-pilot-voice-filter` (HEAD `fd0d4b2`)
PR: [#2 — feat: wire local ATC voice-filter phase one](https://github.com/daocism/dspeech/pull/2) (OPEN)

## Supervisor verdict

**BLOCKED — run produced no audit, implementation, or verification artifact for dspeech.**

The supervisor was told to gate on
`.ai/runs/dspeech-supervisor-20260523T132443Z-1c576edf-{audit,implementation,verification}.md`.
None of these files exist in the canonical dspeech repo. The branch
HEAD on `origin/feat/local-pilot-voice-filter` is unchanged at
`fd0d4b2` (the pre-dispatch tip), so no new dspeech code or tests
landed in this cycle.

Two structural workflow bugs (see next section) made the failure
inevitable: the dispatched workers were composed for the wrong
project (web frontend roles for an iOS Swift app) **and** their
worktrees were materialised against the wrong git repo (MyInfra,
not dspeech). No worker could have written a dspeech artifact even
if it ran to completion.

Per the brief's instruction — "If neither appears, create a final
report that says the run is blocked by missing upstream artifacts" —
this report is that final.

## Workflow bugs found/fixed

### B1. Wrong worktree repo (CRITICAL — primary cause of empty run)

All three worker worktrees under
`/tmp/ai-office-runs/dspeech-supervisor-20260523T132443Z-1c576edf/`
(`wt-engineer-frontend/`, `wt-tester-unit/`, `wt-qa-manual/`) are
checked out against the **MyInfra** repository, not dspeech:

```
$ cd wt-engineer-frontend && git log --oneline -1
894d876 fix(observability): sanitize fleet-alert triage filenames + honest failures
$ git status --short --branch
## HEAD (no branch)
```

`894d876` is a MyInfra commit. dspeech HEAD is `fd0d4b2`. Workers
writing into these worktrees cannot reach dspeech sources, cannot
commit to `feat/local-pilot-voice-filter`, and cannot produce any
artifact under dspeech `.ai/runs/`.

Fix (not applied this run — out of scope for qa-manual reporter
authority): the team-dispatch worktree provisioner must read the
project's canonical repo from the registry
(`MyInfra/config/project-workspaces/projects.yaml` for `dspeech`)
and `git worktree add` from `/home/user/projects/dspeech`, not from
the orchestrator's current cwd. Filed as a real workflow bug to
escalate.

### B2. Role composition mismatched to project (CRITICAL)

The dispatch picked `engineer-frontend`, `tester-unit`, `qa-manual`.
For an iOS Swift app shipping via the App Store, the correct
composition is the SwiftUI/iOS subset
(`swiftui-implementer`, `tester` for XCTest, `qa-manual` is fine for
device walkthroughs). None of the chosen roles writes Swift, runs
`xcodebuild`, or knows about FluidAudio / `AVAudioSession`. The
visible effect in the streams:

- `engineer-frontend` spent the run writing a **research markdown**
  about audio route changes — duplicating work already in
  `docs/research/2026-05-23-audio-route-health.md` from the prior
  builder run (commit `fd0d4b2`).
- `tester-unit` is sitting in a polling loop waiting for
  `*-implementation.md` that no participant in this composition can
  ever produce.
- `qa-manual` (this reporter) was the only role with a meaningful
  brief, and only because the brief was rewritten to "act as the
  final supervisor reporter" instead of "drive Playwright".

Fix (not applied this run): the dispatcher must use the project's
declared team profile from the workspace registry rather than a
default web-app composition. Project `dspeech` should pin
`swiftui-implementer` + `tester` (XCTest) + `qa-manual` (sim
walkthrough) at minimum.

### B3. Supervisor gate artifact names are unenforced

The supervisor brief names three required upstream files
(`-audit.md`, `-implementation.md`, `-verification.md`) but the
dispatch contract does not require the workers to emit files at
exactly those paths. With the wrong roles (B2) the names never line
up. The "depends_on" note in the brief acknowledges this is
unenforced.

Fix recommendation: either (a) make the dispatcher inject required
output paths into each worker's brief and refuse to mark the worker
"done" without that file existing, or (b) loosen the supervisor to
accept any worker artifact and synthesise its own audit row.

### B4. Recurring mac24 worker auth failure (carried over from previous run)

Documented in the supervisor brief: the previous builder run
`dspeech-builder-20260523T115550Z-4fea767f` failed because mac24
Claude returned `Not logged in · Please run /login` for the
implementation and testing workers. This is a fleet-level workflow
defect for any iOS project (mac24 is the only fleet host that can
run `xcodebuild` + simulator). It must be fixed before any future
Dspeech run can land Swift code. Brief constraint "Do not use mac24
as an autonomous worker" closes the door on a workaround — the only
real fix is to restore mac24 Claude auth (manual `/login`) and
re-enable mac24 dispatch.

## Product risks

P1. **Open PR #2 is still phase-1 only.** It correctly ships the
post-ASR callsign relevance gate and the local-only Pilot 1 / Pilot
2 enrollment UI (disabled with explicit "local model unavailable"
banner per ADR 0007). What it does NOT ship — and what the product
north star needs:

   - Pre-ASR pilot suppression actually wired to a real local
     speaker identifier (FluidAudio / CoreML pack). Today's `Core/
     VoiceFilter` ships the protocol and cosine matcher but the
     identifier is stubbed.
   - Audio route health classifier from the research handoff
     (`docs/research/2026-05-23-audio-route-health.md`, sections
     §3-§5). The research is committed; the Swift implementation is
     not.
   - XCTest coverage on the simulator for the route-health
     classifier and `FakeAudioSessionRouting`.

P2. **ATC-only transcript reliability not yet measured.** Phase-1
gate filters by callsign continuation, but there is no eval harness
yet to score "% of pilot self-talk leaked into ATC transcript" on a
captured set. Without that, regressions when the real speaker
identifier lands won't be visible.

P3. **No simulator smoke or device validation in this PR.** PR #2
body lists a `xcodebuild ... iPhone 17 Pro` test plan but
`statusCheckRollup: []` shows no CI check has run, and the supervisor
run produced no new test evidence. The PR is technically reviewable
but functionally unverified for this cycle.

P4. **Bluetooth/radio receiver lane carries unknowns.** The research
doc parks `BluetoothLE (LE-Audio)`, vendor-headset recognition by
`portName`, `airPlay` as input, and `hasHardwareVoiceCallProcessing`
preference policy. These will surface as real-user friction the
first time a pilot pairs a real headset, but cannot be closed in
simulator. No purchase is needed *yet* — the route-health classifier
+ `FakeAudioSessionRouting` lane lets us land the UX and revisit on
real hardware later.

P5. **No regression risk introduced this cycle** — branch HEAD is
unchanged. The risk is opportunity cost, not breakage.

## Next cycle priority

In order, product-north-star first:

1. **Land the route-health classifier and `AudioSessionRouting`
   protocol in Swift** per the research doc's "Exact recommendations
   for the engineer" §1–§7. Pure-function classifier +
   `LiveAudioSessionRouting` (sole `AVFAudio` importer) +
   `FakeAudioSessionRouting`. Tests: classifier unit tests over
   JSON fixtures in `tests/Fixtures/AudioRoute/*.json`, one VM
   integration test per `RouteHealth` value, one banner test for
   `.oldDeviceUnavailable`. This is the gate for "reliable ATC-only
   transcript" — once route-health is enforced pre-ASR, the
   transcript stops ingesting clearly-bad audio.

2. **Wire pre-ASR pilot suppression to a real local speaker
   identifier.** Replace the stubbed `LocalSpeakerIdentifier` with
   the FluidAudio-backed implementation, ship a model-pack download
   + on-device install UX, and enable Pilot 1 / Pilot 2 enrollment
   slots. Eval target: callsign-gated ATC transcript should drop
   pilot self-talk below an internally-set threshold on a captured
   reference set.

3. **Simulator + device smoke + App Store readiness.** XCTest
   matrix on `iPhone 17 Pro` (sim) and the latest available device
   target. Privacy nutrition labels, microphone usage strings, App
   Store metadata first pass. This is the "ship" gate.

4. **Bluetooth/radio receiver validation lane — design now, run
   later.** Add a hardware-validation checklist + a `FakeRoute`
   matrix for the headset models we expect (HFP, A2DP, LE-Audio,
   AirPlay-as-input). Lane is a doc + harness; no headset purchase
   required this cycle. Schedule actual hardware test for the cycle
   *after* App Store TestFlight is live so we have real pilots to
   borrow gear from.

Explicitly NOT priorities this cycle (deferred): cloud ASR fallback,
multi-language UI, marketing site polish, third-party headset
vendor recognition.

## Real user-side blockers

R1. **No working build artifact landed.** A pilot wanting to try
Dspeech today gets exactly what was on the branch yesterday — the
phase-1 callsign gate, no pre-ASR voice filter, no route health UI.
This run did not move the user-visible product.

R2. **mac24 cannot autonomously build & test.** Until the mac24
Claude `/login` is restored, every iOS code change must be merged
on faith (no auto-CI in this repo). Manually-triggered `xcodebuild`
on mac24 is the only path right now. User cost: each merge waits
for a human-in-the-loop on one specific machine.

R3. **No staging surface for the iOS app.** Unlike a web project,
qa-manual cannot Playwright-walk an iOS binary; Simulator + device
QA must run on mac24. So "the qa-manual final acceptance gate" is
unavailable for this product until mac24 dispatch returns. None of
the screenshots / mobile/desktop sweeps in the qa-manual role brief
apply — the brief was overridden to "final supervisor reporter" for
exactly that reason.

R4. **App Store path is not yet started.** No bundle ID
provisioning, no TestFlight build, no App Store Connect metadata.
This is a multi-cycle blocker for "Dspeech in pilots' hands". Flag,
not fix.

## Evidence

### Run artifacts (under `.ai/runs/`)

```
README.md
f1abcd97-137f-43ba-a935-26d01dab747a-codebase-map.md
dspeech-builder-20260523T115550Z-4fea767f-research.md
dspeech-supervisor-20260523T132443Z-1c576edf-final.md   <-- this report
```

No `-audit.md`, no `-implementation.md`, no `-verification.md` for
this run. The only other run-scoped file
(`dspeech-builder-20260523T115550Z-4fea767f-research.md`) is from
the previous, failed builder run; it was committed as
`fd0d4b2 docs(audio): research route health validation` and is the
current branch tip.

### Git state

```
$ git log --oneline --decorate --max-count=5
fd0d4b2 (HEAD -> feat/local-pilot-voice-filter, origin/feat/local-pilot-voice-filter)
  docs(audio): research route health validation
e4cf7ce feat(voice-filter): wire callsign gate phase one
76e9ab8 (origin/main, origin/HEAD, main) docs(ai): add Project Workspace memory skeleton (#1)
bb8013f feat(asr): wire on-device live transcription MVP (Apple Speech)
b48875a chore: add mac24 Dspeech agent orchestrator wrapper

$ git status --short --branch
## feat/local-pilot-voice-filter...origin/feat/local-pilot-voice-filter
(no local changes)
```

`HEAD == origin/feat/local-pilot-voice-filter == fd0d4b2`. Branch is
already pushed and synchronized with remote. No new dspeech commits
this run.

### Worker worktree git state (proves B1)

```
$ cd /tmp/ai-office-runs/dspeech-supervisor-20260523T132443Z-1c576edf/wt-engineer-frontend
$ git log --oneline -1
894d876 fix(observability): sanitize fleet-alert triage filenames + honest failures
$ git status --short --branch
## HEAD (no branch)

$ cd ../wt-tester-unit && git log --oneline -1
894d876 fix(observability): sanitize fleet-alert triage filenames + honest failures
$ git status --short --branch
## HEAD (no branch)
```

`894d876` is a MyInfra commit (visible in this repo as
`git -C ~/projects/MyInfra log --oneline -1`). The dspeech repo's
HEAD is `fd0d4b2`. The worker worktrees are pointing at the wrong
project's git history — primary cause of the empty run.

### Worker stream snapshots (under `/tmp/ai-office-runs/<run>/streams/`)

```
-rw-rw-r-- engineer-frontend.jsonl   106 KB   (last event: requesting)
-rw-rw-r-- qa-manual.jsonl            86 KB   (this reporter, active)
-rw-rw-r-- tester-unit.jsonl          83 KB   (in bounded polling loop for *-implementation.md)
```

Engineer-frontend's final tool call wrote a 302-line markdown
documenting `AVAudioSession` route-change handling — substantially
overlapping the already-committed
`docs/research/2026-05-23-audio-route-health.md`, and not into the
dspeech repo. Tester-unit's polling loop is searching for the
implementation artifact in dspeech `.ai/runs/`; loop will exhaust
without finding it.

### PR #2 metadata (GitHub reachable)

- URL: <https://github.com/daocism/dspeech/pull/2>
- State: OPEN
- Base: `main` (`76e9ab8`)
- Head: `feat/local-pilot-voice-filter` (`fd0d4b2`)
- Commits in PR (2):
  - `e4cf7ce feat(voice-filter): wire callsign gate phase one` (2026-05-22)
  - `fd0d4b2 docs(audio): research route health validation` (2026-05-23)
- `statusCheckRollup: []` — no CI checks attached to this PR.

PR body cleanly states the phase-1 scope and that real FluidAudio
+ pre-ASR routing remains; matches §"Product risks" P1 above.

### Notion access

The supervisor brief notes the Notion MCP returned `NOT_FOUND` from
the supervisor session for the active Dspeech task/run rows. This
reporter session does not have a Notion MCP transport attached
either; per the brief's "do not invent Notion state" instruction,
Notion state is unknown for this run. Repo artifacts (this file +
`.ai/project-state.md` + PR #2 body) remain canonical.

### Repo project-state pointer

`.ai/project-state.md` last "Last successful run" entry is
`2026-05-22`, which predates this supervisor run and remains the
factual last successful Dspeech run. This report does not update
`project-state.md` because the current run produced no successful
outcome to record.

---

End of report. No source code changed. No PR #2 update made by this
reporter (PR body already accurately describes the phase-1 scope;
updating it would invent supervisor-cycle status that the workflow
bugs above prevented us from earning).
