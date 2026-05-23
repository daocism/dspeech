# Dspeech supervisor — final report

Run ID: `dspeech-supervisor-20260523T132443Z-1c576edf`
Reporter: `qa-manual` (acting as final supervisor reporter per dispatch brief)
Host: `ubuntu-vm`
Canonical repo: `/home/user/projects/dspeech`
Branch: `feat/local-pilot-voice-filter` (HEAD `fd0d4b2`)
PR: [#2 — feat: wire local ATC voice-filter phase one](https://github.com/daocism/dspeech/pull/2) (OPEN)

## Supervisor verdict

**PARTIAL — uncommitted Swift implementation present in working tree,
no tests, no xcodebuild, no audit/implementation/verification
artifact written to `.ai/runs/`.**

The supervisor's required upstream artifacts
(`.ai/runs/dspeech-supervisor-20260523T132443Z-1c576edf-{audit,
implementation,verification}.md`) do **not** exist. The branch HEAD
on `origin/feat/local-pilot-voice-filter` is unchanged at `fd0d4b2`
(the pre-dispatch tip), so no new dspeech code landed in `git` this
cycle.

However, mid-run inspection of the working tree turned up **four
new, well-formed Swift files** in the canonical repo at
`Dspeech/Core/Audio/`, written at 15:34–15:35 UTC and matching §1–§4
of the prior research handoff's "Exact recommendations for the
engineer":

- `RouteHealthTypes.swift` (3.5 KB) — domain types
  (`AudioPortType`, `PortSnapshot`, `RouteSnapshot`, `RouteHealth`,
  `RouteHealthAssessment`, `RouteChangeEvent`, `RouteChangeNotice`).
- `RouteHealthClassifier.swift` (1.9 KB) — pure
  `enum RouteHealthClassifier.classify(route:availableInputs:)`,
  five-state output matching the research doc.
- `AudioSessionRouting.swift` (2.4 KB) — `protocol
  AudioSessionRouting: Sendable` + `FakeAudioSessionRouting` (test
  fake with manual `emit` / `updateRoute`).
- `LiveAudioSessionRouting.swift` (production adapter) — sole
  `AVFAudio` importer, behind `#if canImport(AVFAudio)`, observing
  `AVAudioSession.routeChangeNotification` and mapping `RouteChange
  Reason` raw values to the domain enum.

These files are **untracked**, never compiled, never tested, and not
added to the Xcode project (`Dspeech.xcodeproj/project.pbxproj` not
modified). The supervisor reporter intentionally **does not commit
them** — they cannot ship without (a) Xcode project membership,
(b) at least the test matrix the research handoff §7 prescribed,
(c) one `xcodebuild ... iPhone 17 Pro` green run on mac24. All three
are outside this reporter's role authority and require either a
swiftui-implementer + tester(XCTest) pair, or mac24 returning to
service.

So: real, useful work was done by some worker; it is parked in the
working tree; the supervisor cycle did not close. Per the brief's
"If neither artifact appears, create a final report that says the
run is blocked by missing upstream artifacts" — this report is that
final, and it captures the in-flight state so the next cycle can
pick up exactly where this one stopped without re-doing it.

## Workflow bugs found/fixed

### B1. Wrong worktree repo (CRITICAL — worker output bypassed git isolation)

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

`894d876` is a MyInfra commit. dspeech HEAD is `fd0d4b2`. The
intent of `git worktree`-per-role isolation is that each worker
edits only inside its worktree, then the orchestrator merges. With
the worktrees pointing at MyInfra, **at least one worker reached
outside its worktree** and wrote directly into the canonical
`/home/user/projects/dspeech/Dspeech/Core/Audio/` path (see
"Supervisor verdict" — four uncommitted Swift files at 15:34–15:35
UTC). This is the worst-of-both-worlds outcome: the worker did real
work, but it landed in a location that bypasses the run's git
isolation contract. No commit was made; no branch was updated;
no review was triggered.

Fix (not applied this run — out of scope for qa-manual reporter
authority): the team-dispatch worktree provisioner must
(a) read the project's canonical repo from the registry
(`MyInfra/config/project-workspaces/projects.yaml` for `dspeech`)
and `git worktree add` from `/home/user/projects/dspeech`, not from
the orchestrator's current cwd; and (b) constrain each role's
allowed Write/Edit paths to its own worktree to prevent
out-of-worktree side effects. Filed as a real workflow bug to
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

P1. **Open PR #2 is still phase-1 only on the branch — but four
uncommitted Swift files in the working tree push it closer.**
PR #2 (on origin) correctly ships the post-ASR callsign relevance
gate and the local-only Pilot 1 / Pilot 2 enrollment UI (disabled
with explicit "local model unavailable" banner per ADR 0007). What
the branch still does NOT ship:

   - Pre-ASR pilot suppression actually wired to a real local
     speaker identifier (FluidAudio / CoreML pack). Today's `Core/
     VoiceFilter` ships the protocol and cosine matcher but the
     identifier is stubbed.
   - Audio route health classifier from the research handoff
     (`docs/research/2026-05-23-audio-route-health.md`, sections
     §3-§5). **The Swift implementation is written but
     uncommitted, not in the Xcode project, and untested** (see
     §Evidence "Untracked Swift implementation"). It is the first
     thing the next cycle must verify and land.
   - XCTest coverage on the simulator for the route-health
     classifier and `FakeAudioSessionRouting` — no `RouteHealth*`
     tests in `DspeechTests/`, no JSON fixtures in
     `tests/Fixtures/AudioRoute/`.

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

1. **Verify, test, and commit the in-flight route-health work
   already on disk.** Four Swift files at `Dspeech/Core/Audio/`
   (`RouteHealthTypes.swift`, `RouteHealthClassifier.swift`,
   `AudioSessionRouting.swift`, `LiveAudioSessionRouting.swift`)
   implement §1–§4 of the research doc and are untracked in the
   working tree. Next cycle must (a) add them to
   `Dspeech.xcodeproj/project.pbxproj`, (b) write the §7 test
   matrix — classifier unit tests over JSON fixtures in
   `tests/Fixtures/AudioRoute/*.json`, one VM integration test per
   `RouteHealth` value, one banner test for `.oldDeviceUnavailable`
   driven by `FakeAudioSessionRouting`, (c) run
   `xcodebuild ... iPhone 17 Pro` on mac24 once, (d) commit + push.
   Only then proceed to §2 (capture-screen chip + route-change
   banner UI from research §2.1/§2.2) and §6 (transcript metadata
   markers). This is the gate for "reliable ATC-only transcript" —
   once route-health is enforced pre-ASR, the transcript stops
   ingesting clearly-bad audio.

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
## feat/local-pilot-voice-filter
?? Dspeech/Core/Audio/AudioSessionRouting.swift
?? Dspeech/Core/Audio/LiveAudioSessionRouting.swift
?? Dspeech/Core/Audio/RouteHealthClassifier.swift
?? Dspeech/Core/Audio/RouteHealthTypes.swift
```

Branch tip pushed: `fd0d4b2` + this report commit. Working tree is
**not clean** — four untracked Swift files left by a worker that
escaped its worktree (see B1). Reporter intentionally did not stage
or commit them (see "Supervisor verdict" rationale).

### Untracked Swift implementation (proof of B1 escape + P1 progress)

```
$ ls -la Dspeech/Core/Audio/
-rw-rw-r-- AudioCaptureService.swift           (282 B, 2026-05-17 20:53)
-rw-rw-r-- AudioSessionRouting.swift          (2.4 KB, 2026-05-23 15:35)  NEW
-rw-rw-r-- LiveAudioSessionRouting.swift            (-, 2026-05-23 15:35)  NEW
-rw-rw-r-- RouteHealthClassifier.swift        (1.9 KB, 2026-05-23 15:34)  NEW
-rw-rw-r-- RouteHealthTypes.swift             (3.5 KB, 2026-05-23 15:34)  NEW
```

All four files compile cleanly to a reader (no obvious syntax
errors; `Sendable` annotations consistent; `LiveAudioSessionRouting`
correctly behind `#if canImport(AVFAudio)`) but have not been built.
`DspeechTests/` contains no `RouteHealth*.swift`. `tests/Fixtures/
AudioRoute/` does not exist. `Dspeech.xcodeproj/project.pbxproj`
has not been modified. Next cycle: §"Next cycle priority" step 1.

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

---

## Addendum (post-report-write, ~15:36 UTC)

After this report's first commit (`3fd78f1`) was pushed, two things
changed in the working tree:

1. **A `verification.md` artifact appeared**, authored by the
   `tester-unit` worker and committed alongside this report's
   correction commit (`3e9c327`). It is now at
   `.ai/runs/dspeech-supervisor-20260523T132443Z-1c576edf-verification.md`.
   Independently authored, it reaches the same B1/B2 root-cause
   verdict from the worker's own perspective — confirming the
   workflow bugs are observable from inside the broken dispatch,
   not just from the supervisor's vantage. Its verdict at write
   time was `BLOCKED: implementation artifact missing` because at
   *its* observation moment the Swift implementation had not yet
   landed in the canonical tree.

2. **Three more Swift files appeared in the working tree** after
   this reporter's initial inspection — pushing the in-flight
   implementation closer to the research handoff's §1–§7 scope:

   - `Dspeech/App/RouteHealthMonitor.swift` (174 lines) —
     `@MainActor @Observable` view-model wrapping
     `RouteHealthClassifier` + `AudioSessionRouting`, exposing
     `assessment`, `lastNotice`, `lastEvent` for SwiftUI surfaces.
   - `DspeechTests/RouteHealthClassifierTests.swift` (113 lines) —
     Swift Testing framework (`@Test`, `#expect`) — covers all
     five `RouteHealth` cases (`noInput`, `cautionBuiltIn`,
     `suitableExternal` via USB/headset/etc., `unsuitableOutputOnly`,
     `unknownExternal`).
   - `DspeechTests/RouteHealthMonitorTests.swift` (103 lines) —
     drives `RouteHealthMonitor` via `FakeAudioSessionRouting`.

   Total in-flight uncommitted state on disk: **7 Swift files**
   (4 production + 1 monitor + 2 tests). This matches research
   handoff §1–§7 quite well, missing only the capture-screen UI
   chip / banner from §2 and the transcript metadata markers from
   §6, plus Xcode project membership (`.pbxproj` not modified).

   These files were still untracked when this addendum was
   written. Reporter continues to intentionally **not** commit
   them — the rationale in the "Supervisor verdict" section
   stands: no xcodebuild has compiled them, no Xcode project lists
   them, and the qa-manual role does not own Swift authorship or
   XCTest validation.

**Implication for the next cycle:** the very first action of the
next dispatched swiftui-implementer is roughly 80% of step 1 in
"Next cycle priority" already on disk; the work item is verification
+ Xcode project membership + commit, not greenfield Swift. The
next cycle's tester is similarly handed a working test suite to
validate.

---

End of report. The reporter committed only the two `*.md` artifacts
(`-final.md`, swept-in `-verification.md`). Seven untracked Swift
files left in the working tree by out-of-worktree workers (B1) are
intentionally **not** committed by this reporter — they require
swiftui-implementer review + Xcode project membership + xcodebuild
verification on mac24 before merge, which is the explicit work item
for the next cycle (§"Next cycle priority" #1). PR #2 body not
updated: it still accurately describes what is on the branch (the
phase-1 callsign gate + research handoff + this run's metadata
commits). Posting supervisor-cycle status into the PR body would
invent merge-readiness that the workflow bugs above prevented us
from earning.
