# Verification — dspeech-builder-20260524T110035Z-ad6fed3d (tester-unit)

Role: tester-unit (evidence owner). Host: ubuntu-vm. Depends on: engineer-generic.
Branch under test: `feat/local-pilot-voice-filter`.

## Commit under test

`d8b753418061abbd81fc8390c81755045ed57abc` — `docs(voice-filter): local speaker model-pack readiness contract`
(HEAD == `origin/feat/local-pilot-voice-filter` on ubuntu-vm at verification time.)

## Headline finding — mission premise unmet (no code slice to verify)

The mission asked me to "verify the model-pack state **code slice** from engineer-generic."
**No such code slice exists on this branch.** The commit under test is **docs-only**:

```
docs/adr/0008-local-speaker-model-pack-readiness.md     | 82 +++
docs/eval/local-speaker-model-pack-validation.md        | 86 +++
docs/run-notes/2026-05-24-local-speaker-model-pack.md   | 38 +++
3 files changed, 206 insertions(+)
```

Authored by the docs-writer run (`dspeech-builder-20260524T070042Z-10c88f5f`), not
engineer-generic. The run note states the scope plainly: *"docs / project-memory only.
No Swift, pbxproj, tests, or Hermes/cron touched."*

ADR 0008 is itself a **contract for a future cycle** — it defines the model-pack state
machine (`absent` / `downloading` / `installed` / `failed` / `disabled`), the
network/privacy invariants, and acceptance gates. It explicitly defers the concrete
`FluidAudioSpeakerIdentifier` backend, the persisted state machine, and the storage
round-trip test to "the next implementation cycle." None of that code was written.

Confirmation that no model-pack state/storage/capability code exists:

- `grep -rE '(ModelPack|modelPack|model-pack|PackState|ModelPackState)'` matches **only**
  markdown (docs/ADR/eval/run-notes/.ai), **zero Swift files**.
- `Dspeech/Core/VoiceFilter/` contents are unchanged from the prior ADR-0007 cycle:
  `ATCTranscriptGate.swift`, `CallSign.swift`, `LocalSpeakerIdentifier.swift`,
  `PilotVoiceProfile.swift`, `SpeakerMatcher.swift`, `VoiceFilterPipeline.swift`,
  `VoiceFilterStorage.swift`. No new model-pack types.
- `DspeechTests/` has no new model-pack/capability test file (`VoiceFilterTests.swift`
  predates this branch HEAD).

The honest gap documented in CLAUDE.md hard rules 2/3 is preserved: the default adapter
is still `UnavailableLocalSpeakerIdentifier`, and `LiveTranscriptionViewModel`
synthesizes `.nonPilot(bestPilotScore: 0)`. No pilot voice is filtered. This commit does
not change that and does not pretend to.

## Dirty-tree caveats

- **ubuntu-vm worktree** (`wt-tester-unit`): clean. `git status --porcelain` empty.
  HEAD detached at `d8b7534` == `origin/feat/local-pilot-voice-filter`.
- **mac24** (`/Users/andre/projects/dspeech-ios`): **DIRTY**. After `git pull --ff-only`
  to `d8b7534`, the working tree carries uncommitted local modifications:
  - `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` — 68-line diff
    (+39/−29). This file is in the main app target and **is compiled into the test
    target**, so the mac24 test results below reflect `d8b7534` *plus* this local mod,
    not the pristine commit.
  - `DspeechUITests/DspeechUITests.swift` — 26-line diff (UI test target only; excluded
    by `-only-testing:DspeechTests`, so no effect on the run below).
  - Untracked: `.agent-logs/`, `.agent-prompts/`, `.agent-state/`,
    `docs/AUTOPILOT-JOURNAL.md`.
  I did **not** stash or revert another agent's WIP on the shared host. The ASR diff is
  unrelated to model-pack/voice-filter; since there is no model-pack code to exercise, it
  does not affect the model-pack conclusion, but it does mean the green result is not from
  a pristine tree.

## Exact commands

```bash
# ubuntu-vm
git status --short --branch
git log --oneline --decorate -5
git show --stat d8b7534
git diff-tree --no-commit-id --name-only -r d8b7534
grep -rE '(ModelPack|modelPack|model-pack|PackState|ModelPackState)'   # → docs only
# privacy scan over each changed file:
grep -nE 'URLSession|NWPathMonitor|import Network|\.dataTask|telemetry|analytics|\.upload' <file>

# mac24 (over ssh, DEVELOPER_DIR exported)
git fetch origin feat/local-pilot-voice-filter
git checkout feat/local-pilot-voice-filter && git pull --ff-only   # → d8b7534
xcrun simctl list devices available           # iPhone 17 / iOS 26.4 present
xcodebuild test -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

## Static privacy scan

Scanned the 3 changed files for new egress/telemetry behavior
(`URLSession`, `Network`, `NWPathMonitor`, `http://`, `https://`, `.dataTask`,
telemetry, analytics, upload):

- **No code-egress API tokens** in any changed file (all three are markdown; no Swift
  changed).
- `https://` appears only as **prose source citations** in ADR 0008 (FluidAudio repo,
  Apple `supportsOnDeviceRecognition` doc) and the FluidAudio `ModelRegistry.baseURL`
  description. These are documentation references, not network code. PASS.
- User-facing copy claims: ADR 0008 and the eval doc are explicit that this slice does
  **not** certify flight safety, transcription correctness, or diarization accuracy, and
  that pilot filtering is **not** active without a real model. No certification /
  guaranteed-correctness / "filtering is active" overclaim introduced. PASS.

## Test results

Full `DspeechTests` on mac24, `iPhone 17 / iOS 26.4` simulator. Run twice for determinism.

| Check | Result |
|---|---|
| ubuntu-vm worktree clean | PASS |
| Commit under test resolved (`d8b7534`) | PASS |
| Privacy scan — no new egress/telemetry code in diff | PASS |
| Privacy scan — no certification / "filtering active" overclaim | PASS |
| Targeted model-pack state/storage/capability unit tests | **N/A — no such code/tests exist** |
| Full `DspeechTests` build + run (mac24, iPhone 17 / iOS 26.4) | PASS — `** TEST SUCCEEDED **` |
| Determinism (2 consecutive runs) | PASS — green both runs, 0 failures |

Suite coverage observed (Swift Testing `@Test`): `PrivacySettingsTests`,
`SpeakerMatcherTests`, `VoiceFilterPipelineTests`, `LiveTranscriptionViewModelTests`,
`CaptureCoordinatorTests`, `RouteHealthMonitorTests`. Zero failed cases across both runs.
(Swift Testing does not emit an XCTest-style "Executed N tests" summary line; evidence is
the per-case `passed` lines plus `** TEST SUCCEEDED **`.)

## Residual risks

1. **Mission/dependency mismatch (primary):** engineer-generic delivered no code on this
   branch HEAD. If a model-pack code slice was expected, it is missing — the supervisor
   should reconcile whether the engineer step ran, or whether this run's true scope was
   docs-only and the brief is stale.
2. **mac24 dirty tree:** the green result is from `d8b7534` + an uncommitted 68-line ASR
   diff on mac24. A from-pristine build was not performed (would require stashing another
   agent's WIP on a shared host, which I declined). The ASR diff is orthogonal to the
   model-pack docs, so confidence in the docs-only conclusion is unaffected, but a truly
   pristine green is unverified on mac24.
3. **Contract-only, unproven:** ADR 0008's privacy/network invariants (one-directional
   model download, offline-verifiable post-install, no silent auto-download) are a
   specification. They are **not yet enforced by any test or code** because the backend
   does not exist. The network-deny integration test and replay fixtures the ADR mandates
   are future work.

## Reviewer verdict

**Safe for reviewer — as a docs/contract commit only.**

`d8b7534` introduces no code, no egress, no overclaim, and the existing `DspeechTests`
suite stays green. It is a clean ADR + eval-plan + run-note addition consistent with the
honest-gap posture of CLAUDE.md hard rules 2–4.

Reviewer must **not** read this as verification of a model-pack *implementation* — there
is none. The model-pack state machine, storage round-trip test, download UX, and
network-deny test enumerated in ADR 0008 §"Acceptance gates" remain unbuilt and unverified.

## Artifact path

`.ai/runs/dspeech-builder-20260524T110035Z-ad6fed3d-verification.md` (this file). The repo
already tracks `.ai/runs/*-verification.md` evidence, so this is committed to the branch.
