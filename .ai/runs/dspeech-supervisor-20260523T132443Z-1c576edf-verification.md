# Dspeech supervisor — verification artifact

Run ID: `dspeech-supervisor-20260523T132443Z-1c576edf`
Reporter: `tester-unit` (running on ubuntu-vm per dispatch brief)
Canonical repo: `/home/user/projects/dspeech`
Branch: `feat/local-pilot-voice-filter` (remote HEAD `3fd78f1`)

## Verdict

**BLOCKED: implementation artifact missing — but a well-formed
implementation is parked uncommitted in the working tree.**

No `.ai/runs/dspeech-supervisor-20260523T132443Z-1c576edf-implementation.md`
exists. The supervisor's required upstream contract was therefore
not met. However, this verifier independently inspected
`/home/user/projects/dspeech` mid-run and found seven uncommitted
Swift files (5 production + 2 test) implementing the route-health
slice from `docs/research/2026-05-23-audio-route-health.md`. The
supervisor's own (locally-modified, also uncommitted) `…-final.md`
draft acknowledges five of these but missed the two test files.

Why this is still "blocked, not pass":

- Files are **untracked** in `git`; remote branch tip is the
  supervisor's BLOCKED report, not new product code.
- Files have **no Xcode project membership**
  (`Dspeech.xcodeproj/project.pbxproj` has zero references to any
  of the new symbols — `grep -E "RouteHealth|AudioSessionRouting"
  Dspeech.xcodeproj/project.pbxproj` returns empty). `xcodebuild
  build test` will neither compile nor execute them.
- **No mac24 build/test was run.** The brief requires
  `xcodebuild ... iPhone 17 Pro` evidence; the supervisor brief
  also restricts autonomous mac24 use because of the unresolved
  `/login` defect from the previous cycle.

Per the brief's "If the implementation never appears, create the
verification artifact stating `BLOCKED: implementation artifact
missing` and include the current git/log evidence" — this file is
that artifact, augmented with a full code review of the working-
tree work so the next cycle can pick up cleanly.

## Self-gate timeline

The tester-unit dispatch ran a bounded polling loop on ubuntu-vm:

- Polled remote `feat/local-pilot-voice-filter` every 30s.
- Polled for `…-implementation.md` under `.ai/runs/`.
- Exited on iter 9 (≈4.5 minutes elapsed) when a new remote commit
  appeared: `3fd78f1 docs(ai): supervisor final report — run
  20260523T132443Z-1c576edf BLOCKED`.
- That commit is the supervisor's first-pass BLOCKED report (not
  an implementation). After pulling, working tree showed seven
  untracked Swift files plus a locally-modified, uncommitted
  revision of the supervisor's `…-final.md` (re-titled "PARTIAL").
- This verifier then code-reviewed the working-tree files in
  place, did not commit them, and authored this artifact.

## Commands run and outcomes

```
$ git -C /home/user/projects/dspeech log --oneline -5
3fd78f1 docs(ai): supervisor final report — run 20260523T132443Z-1c576edf BLOCKED
fd0d4b2 docs(audio): research route health validation
e4cf7ce feat(voice-filter): wire callsign gate phase one
76e9ab8 docs(ai): add Project Workspace memory skeleton (#1)
bb8013f feat(asr): wire on-device live transcription MVP (Apple Speech)

$ git -C /home/user/projects/dspeech status --short --branch
## feat/local-pilot-voice-filter...origin/feat/local-pilot-voice-filter
 M .ai/runs/dspeech-supervisor-20260523T132443Z-1c576edf-final.md
?? Dspeech/App/RouteHealthMonitor.swift                  (174 lines)
?? Dspeech/Core/Audio/AudioSessionRouting.swift          ( 79 lines)
?? Dspeech/Core/Audio/LiveAudioSessionRouting.swift      ( 91 lines)
?? Dspeech/Core/Audio/RouteHealthClassifier.swift        ( 53 lines)
?? Dspeech/Core/Audio/RouteHealthTypes.swift             (126 lines)
?? DspeechTests/RouteHealthClassifierTests.swift         (113 lines)
?? DspeechTests/RouteHealthMonitorTests.swift            (103 lines)

$ git -C /home/user/projects/dspeech diff --check
(clean — no whitespace/conflict markers in the tracked diff)

$ grep -E "RouteHealth|AudioSessionRouting|RouteHealthMonitor" \
     Dspeech.xcodeproj/project.pbxproj
(no matches — new files are NOT in the Xcode project)

$ grep -rn -E "URLSession|HTTPS?|Cloud|certif|FAA|radio link|tower link" \
     Dspeech/Core/Audio/ Dspeech/App/RouteHealthMonitor.swift
(only matches are the test file's anti-cert-language guards in
 DspeechTests/RouteHealthMonitorTests.swift lines 98-100)
```

`xcodebuild` on mac24 was **deliberately not run** this cycle:

- Building the remote HEAD (`3fd78f1`) would compile a docs-only
  delta the previous cycle already covered.
- The new working-tree files are not in the Xcode project, so even
  if they were committed and pushed, `xcodebuild ... iPhone 17 Pro`
  would not compile them (no target membership).
- The brief explicitly says "Do not use mac24 as an autonomous
  worker" because of the carried-over `/login` defect; running an
  ineffectual build to satisfy a checklist would waste compute
  and risk re-triggering that defect for no signal.

If the next cycle commits these files and adds Xcode project
membership, the deterministic command from the brief is:

```
ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  git fetch origin feat/local-pilot-voice-filter && \
  git checkout feat/local-pilot-voice-filter && git pull --ff-only'

ssh mac24 'cd /Users/andre/projects/dspeech-ios && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  CODE_SIGNING_ALLOWED=NO build test'
```

If `iPhone 17 Pro / iOS 26.4` is unavailable, fall back to the
output of `xcrun simctl list devices available` and pick the
nearest available iPhone simulator.

## Code review of the parked working-tree implementation

Reviewed all seven files against the brief's product checks. Order
is by severity (most user-impacting first).

### Severity LOW / informational — what the code gets right

1. **Local/offline behavior.** No `URLSession`, no `URLRequest`,
   no `https://`, no Cloud SDK imports. Pure Foundation +
   conditional `AVFAudio` only.
2. **No flight-safety / certification copy.** Russian-language
   user strings in `RouteHealthMonitor.swift` are operationally
   neutral ("Внешний вход", "Микрофон iPhone", "Только вывод —
   нет входа", "Неизвестный вход", "Нет входа", "Запись
   приостановлена"). No "certified", "approved", "FAA", "radio
   link", "tower link". The test
   `RouteHealthMonitorTests.displayCopyAvoidsCertifiedLanguage`
   sweeps every `RouteHealth.displayLabel` for "certif", "radio
   link", "tower link" — an excellent regression guard.
3. **No persisted route UID.** `setPreferredInput(uid:)` exists
   on the protocol; `LiveAudioSessionRouting` resolves it through
   `session.availableInputs` and calls `setPreferredInput(port)`
   in-memory only. The fake stores the UID in an in-process
   `[String]` for assertion. Nothing reaches `UserDefaults`, no
   keychain write, no file write.
4. **Source audio / replay remains canonical.** These files are
   purely an observation+classification layer on top of
   `AVAudioSession`'s current route. They do not buffer audio,
   do not gate the capture path, and do not introduce a new
   "trust this label over the audio" surface. `RouteHealth` is
   advisory; the user's source recording (per project north star)
   stays canonical.
5. **`AVFAudio` isolation.** `Dspeech/Core/Audio/
   LiveAudioSessionRouting.swift` is the only file importing
   `AVFAudio`, and it does so behind `#if canImport(AVFAudio)`.
   All other Audio files import `Foundation` only; `RouteHealth
   Monitor.swift` imports `Foundation` + `Observation`. Tests
   import `Foundation` + `Testing` + `@testable import Dspeech`.
   This is the "sole adapter" shape the research handoff §1
   prescribed.
6. **Classifier coverage of every `RouteHealth` state.** Five
   states, all covered by `RouteHealthClassifierTests`:
   - `.noInput` → `emptyRouteAndNoInputsIsNoInput`
   - `.cautionBuiltIn` → `builtInMicIsCaution`
   - `.suitableExternal` → `usbAudioIsSuitableExternal`,
     `headsetMicIsSuitableExternal`, `lineInIsSuitableExternal`,
     `bluetoothHFPIsSuitableExternal`, `carAudioIsSuitableExternal`
   - `.unsuitableOutputOnly` →
     `bluetoothA2DPOnlyAvailableIsUnsuitable`,
     `bluetoothA2DPDirectInputIsUnsuitable`
   - `.unknownExternal` → `unknownPortTypeIsUnknownExternal`
   Plus a round-trip test for `AudioPortType` raw values and an
   `isOutputOnly` table check.
7. **Notice mapping covered in `RouteHealthMonitorTests`.**
   `.lost` (external → built-in transition), `.improved` (built-in
   → external climb), `.noSuitableRoute` (route emptied with
   `noSuitableRouteForCategory` event), `.silent` (`categoryChange`),
   plus `blocksStart` invariant.

### Severity MEDIUM — must be addressed before merge

8. **Files are not in the Xcode project.** This is the gating
   defect. Without `Dspeech.xcodeproj/project.pbxproj` entries,
   neither the production code nor the tests are part of any
   target, so `xcodebuild build test` silently builds the pre-
   existing target as-is and reports green without ever touching
   the new code. A reviewer trusting CI would conclude (falsely)
   that the route-health slice is verified. The implementer or
   the swiftui-implementer follow-up must add target membership
   (`Dspeech` target for the five production files; `DspeechTests`
   target for the two test files) before push.
9. **`bluetoothLE` and `airPlay` route into `.suitableExternal`
   without test coverage.** The classifier maps both to "suitable
   external" (`RouteHealthClassifier.swift` line 27), but no test
   exercises either case. The research doc explicitly parked
   these as "unknowns to validate on real hardware". Safer
   short-term choice: route them through `.unknownExternal` (so
   the UX shows "Неизвестный вход" rather than the green "Внешний
   вход" state until they're validated on real LE-Audio / AirPlay-
   as-input hardware), and/or add explicit test cases pinning
   whichever decision is taken.
10. **Notice kind `.improved` is emitted when the *primary input*
    changes but health rank also rises.** That is fine. But the
    converse — primary input changing from `external#1` to
    `external#2` (both `.suitableExternal`) — emits `.silent`,
    not `.improved`. For a pilot swapping between two USB taps,
    that may be surprising. Minor UX call; either is defensible.
    Worth a test pinning the chosen behavior.
11. **No fixture-based JSON tests.** The research handoff §7
    suggested `tests/Fixtures/AudioRoute/*.json`. The current
    test file inlines `PortSnapshot` literals instead, which is
    easier to read but harder to extend when real-device data
    captures come back. Acceptable for now; flag for later
    cycles when device test data lands.

### Severity HIGH — none

No memory-safety, threading, retention, or correctness bugs found
in the working-tree files at the level of the brief's checks.
`FakeAudioSessionRouting` uses `@unchecked Sendable` with NSLock
for mutable state, which is the standard Swift 6 pattern; the
`AsyncStream` continuation is captured once and reused for both
construction and `emit`. `LiveAudioSessionRouting` cleans up the
NotificationCenter observer in `deinit` and finishes the stream
continuation.

### Severity CRITICAL — none in the code itself

The only CRITICAL items are workflow, not code:

C1. **Worker worktree provisioner pointed at MyInfra, not
    dspeech.** This verifier's own worktree
    (`/tmp/ai-office-runs/.../wt-tester-unit`) is checked out
    against MyInfra (HEAD `894d876`, "## HEAD (no branch)"). Any
    work this verifier does is invisible to dspeech unless the
    verifier reaches out to `/home/user/projects/dspeech`
    explicitly (which is what this run did). Filed independently
    as B1 in the supervisor's `…-final.md` draft.
C2. **Role composition picked `engineer-frontend` + `tester-unit`
    + `qa-manual`** for an iOS Swift project that needs
    `swiftui-implementer` + `tester` (XCTest) + `qa-manual`. That
    no Swift was committed in this cycle is a direct consequence
    — the implementer never had an explicit Swift authoring
    contract. The fact that complete, well-formed Swift code
    nonetheless exists in the working tree suggests one of the
    workers improvised, but had no commit/push authority for
    iOS code, so it sits untracked. Filed as B2 in the
    supervisor's draft.

## Fixes applied

**None.** This worker is in role `tester-unit` and has authority to
edit only test files. Editing production code is out of role. More
importantly, no fix this worker could make would close the gate:

- Adding test cases for `bluetoothLE` / `airPlay` would not
  compile because the files have no Xcode project membership.
- Committing the parked Swift files without `project.pbxproj`
  updates would land a phantom file set that doesn't build.
- Editing the supervisor's locally-modified `…-final.md` is out
  of role for this verifier.

The right next step is a swiftui-implementer pass that:

1. Adds the five production files to the `Dspeech` target.
2. Adds the two test files to the `DspeechTests` target.
3. Re-runs `xcodebuild -project Dspeech.xcodeproj -scheme Dspeech
   -destination "platform=iOS Simulator,name=iPhone 17 Pro,
   OS=26.4" CODE_SIGNING_ALLOWED=NO build test` on mac24.
4. Decides the `.bluetoothLE` / `.airPlay` mapping (recommend:
   route through `.unknownExternal` until hardware-validated)
   and adds tests pinning that decision.
5. Commits and pushes; supervisor cycle then re-runs.

Followed by a tester / tester-pbt pass for the property-based
properties on the classifier (idempotence: classifying twice
yields the same `RouteHealthAssessment`; monotonicity: any
permutation of the same `availableInputs` produces the same
health when `route.inputs` is the same; closure: every
`AudioPortType` raw value round-trips).

## Remaining product risks

R1. **No new user-visible product this cycle.** Branch tip on
remote is the supervisor's BLOCKED report; pilots see exactly the
phase-1 callsign gate from yesterday.

R2. **Parked working-tree implementation is one workflow gust
away from being lost.** If anyone runs `git clean -fdx` or
`git stash` in `/home/user/projects/dspeech`, all 739 lines of
route-health work disappear. The next cycle must either commit
these files (with Xcode project membership) or explicitly stash
them with a labeled, indexed stash entry. This is the highest
short-term risk to the product because it's the difference
between "next cycle picks up from §7-finished work" and "next
cycle re-implements from the research doc".

R3. **mac24 Claude `/login` defect carries over from previous
cycle.** The brief's mitigation ("Do not use mac24 as an
autonomous worker") is correct for *this* cycle but is not a
permanent fix. iOS dev velocity is gated on this.

R4. **Pre-ASR pilot suppression still stubbed.** Phase-1 callsign
gate at `e4cf7ce` is post-ASR. The real product win (real
on-device `LocalSpeakerIdentifier`, FluidAudio / CoreML model
pack) is not in flight in any worktree this cycle and is the
HIGH-severity product gap.

R5. **App Store path not yet started.** No bundle ID
provisioning, no TestFlight build, no Connect metadata.
Multi-cycle blocker for "Dspeech in pilots' hands".

R6. **No CI on PR #2.** `statusCheckRollup: []` per the supervisor
draft. Every iOS merge happens on faith until mac24 dispatch is
restored or a hosted-runner alternative exists.

## PR #2 state

**Blocked / draft.** PR #2 still carries the same two product
commits as before this cycle:

- `e4cf7ce feat(voice-filter): wire callsign gate phase one` (2026-05-22)
- `fd0d4b2 docs(audio): research route health validation` (2026-05-23)

Plus the new run-metadata commit on the branch:

- `3fd78f1 docs(ai): supervisor final report — run 20260523T132443Z-1c576edf BLOCKED`

Recommendation: do not merge. The route-health Swift slice — the
work that genuinely advances PR #2 toward "phase 2" — is parked
uncommitted in the working tree. Next cycle should:

1. Adopt the parked working-tree files (or have a swiftui-
   implementer re-author them), add Xcode project membership,
   land green `xcodebuild build test` on mac24, push the resulting
   commit(s) onto `feat/local-pilot-voice-filter`.
2. Decide the `.bluetoothLE` / `.airPlay` mapping with a test
   pinning the decision.
3. Update PR #2 body to describe the route-health classifier
   slice now in scope.
4. **Then** re-evaluate merge-readiness.

## Real user-side blocker

**mac24 Claude `/login` defect plus the dispatcher's project-blind
worktree provisioner are the two things blocking the user from
seeing forward motion on Dspeech today.** Everything else
(route-health classifier, FluidAudio pre-ASR suppression, Xcode
project membership, App Store path) is workable once those two
workflow defects are resolved. The route-health implementation
itself is essentially done at the code level; what's missing is
the workflow that can compile, test, commit, and push it
autonomously without sitting in a 5-host fleet's working tree.

---

End of verification artifact. No source code changed by this
worker. The seven parked Swift files in
`/home/user/projects/dspeech` working tree are **intentionally
left untracked by this verifier** for the swiftui-implementer or
supervisor to commit (with project.pbxproj edits + mac24 build
evidence).

---

## Addendum (post-write): state moved as the verifier worked

Between the code-review pass above and the moment this artifact
was staged, an out-of-band edit landed in
`/home/user/projects/dspeech` working tree:

- `Dspeech.xcodeproj/project.pbxproj` is now locally modified
  (28 lines changed, 21 insertions / 7 deletions).
- The diff adds all five production files to the `Dspeech` target
  Sources build phase (`A00000000000000000000018`) — under
  `App/` for `RouteHealthMonitor.swift` and under `App/Audio/` for
  the four `Audio` files — and both test files to the
  `DspeechTests` target Sources build phase
  (`A00000000000000000000021`).
- New `PBXFileReference` and `PBXBuildFile` entries use the same
  zero-padded ID style (`A000…0098`–`A000…0110`) already in use
  elsewhere in the project; grouping matches the existing `App`
  and `Audio` groups.
- The supervisor's earlier locally-modified `…-final.md` revision
  ("PARTIAL" wording) has been reverted in the working tree since
  the verifier inspected it; the remote `…-final.md` (the
  original BLOCKED draft from commit `3fd78f1`) is the current
  on-disk state.

This downgrades MEDIUM finding #8 ("Files are not in the Xcode
project") in scope: the file-membership work is now staged on
disk. The remaining gate for that finding is the commit + push
+ mac24 `xcodebuild ... iPhone 17 Pro` green run. None of the
three has happened as of this artifact's write.

This verifier still commits **only** this verification artifact.
The pbxproj edit and the seven Swift files remain unstaged for
the swiftui-implementer / supervisor to claim authorship via a
proper conventional commit ("feat(audio): land route-health
classifier + AVAudioSession adapter") plus the mac24 build
evidence. tester-unit role authority does not include committing
production source or Xcode project files; that boundary is
preserved here.

If the next cycle wants to adopt this verifier's findings:

1. Confirm pbxproj groups place `RouteHealthMonitor.swift` under
   `Core/Audio/` not `App/` (the current placement under `App/`
   may have been a mis-grouping by the out-of-band editor — the
   file is a view model and could equally live under `App/`,
   though its dependencies all live in `Core/Audio/`). Either is
   defensible; pick one and pin it.
2. Decide the `.bluetoothLE` / `.airPlay` mapping (MEDIUM finding
   #9). Recommend routing through `.unknownExternal` until
   hardware-validated; add tests.
3. Commit the production files + test files + pbxproj edit as
   one atomic `feat(audio)` commit. Push.
4. Run the mac24 `xcodebuild build test` command from the
   "Commands run and outcomes" section above. Paste the tail of
   the output into the implementation artifact.
5. Then the supervisor cycle can close clean.
