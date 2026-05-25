# Run note — speaker-identifier factory/gate slice (2026-05-25)

Run: `dspeech-builder-20260525T070045Z-aac9d282`, worker `engineer-generic`.
Branch: `feat/local-pilot-voice-filter`. Commit: **`fd10aa0`** (rebased onto `0fda374`).

## Path taken: fallback (enabling gate layer), not FluidAudio SPM wiring

The mission's preferred path was wiring the `FluidAudio` SPM product and a
`FluidAudioSpeakerIdentifier`. I took the **fallback path** the mission defines,
because:

- This Xcode project does **not** use `PBXFileSystemSynchronizedRootGroup`; every
  source file is listed manually in `Dspeech.xcodeproj/project.pbxproj`. Adding an
  SPM product + a new backend file requires pbxproj surgery (package reference,
  build-file/file-reference/group/sources entries) that cannot be build-validated
  on `ubuntu-vm` (no Xcode), and CLAUDE.md forbids renumbering existing pbxproj IDs.
- The research contract `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md`
  landed concurrently (commit `0fda374`, picked up on rebase), but adding an
  unbuildable SPM dependency blind would violate "no half-implementation".

So this slice lands the substitution point that a FluidAudio backend plugs into,
with **zero new files** (no pbxproj risk) and full green tests.

## Files changed

| File | Change |
|---|---|
| `Dspeech/Core/VoiceFilter/LocalSpeakerIdentifier.swift` | New `protocol LocalSpeakerBackendBuilder` + `enum LocalSpeakerIdentifierFactory.make(state:backendBuilder:)`. Additive; no existing symbol changed. |
| `Dspeech/Core/VoiceFilter/ModelPackState.swift` | `InstalledModelPack.localModelPath: String?` (manual-model-path contract) + explicit init with the param defaulted to `nil`. Backward-compatible Codable (legacy JSON → `nil`). |
| `Dspeech/App/ContentView.swift` | Default pipeline identifier now comes from `LocalSpeakerIdentifierFactory.make(state:)` reading `UserDefaultsModelPackStateStorage`; `backendBuilder` defaults `nil` → stays unavailable today. |
| `DspeechTests/VoiceFilterTests.swift` | New `LocalSpeakerIdentifierFactoryTests` (15 tests). |

## Factory contract (the gate)

`LocalSpeakerIdentifierFactory.make` returns `UnavailableLocalSpeakerIdentifier`
(→ pipeline never `.ready`, no pilot audio dropped before ASR) for **every** case
except a fully-good backend:

- `.absent` / `.acquiring` / `.failed` / `.disabled` → unavailable (uses
  `state.capabilityReason`).
- `.installed` **without** a registered `backendBuilder` (today's shipping reality)
  → unavailable. *Installed-without-backend does not mark the pipeline ready.*
- `.installed` + builder that **throws** → unavailable (fail-open).
- `.installed` + builder whose identifier reports `.unavailable` → unavailable.
- `.installed` + builder whose `embeddingDimension` ≠ `pack.embeddingDimension`
  → unavailable.
- `.installed` + builder returning an available, dimension-matching identifier
  → that concrete identifier (only here does the pipeline become `.ready`).

## Privacy guarantees (unchanged, now enforced through one gate)

- No new network code, no SPM dependency, no cloud path. ADR 0002 intact.
- No silent model download: construction is gated on persisted `ModelPackState`;
  a missing/absent pack yields an identifier that throws `modelUnavailable`.
- `LOCAL`/`CLOUD` badge still bound to `privacy.allowCloud` (untouched).
- UI copy unchanged and still honest: `absentContent` and the `!identifierAvailable`
  banner state the recognizer is not connected in this build — no pilot-suppression
  claim is made unless a real backend is available.

## Tests / build

Verified on mac24 in a **throwaway detached worktree** from the pushed commit, so
the canonical dirty `dspeech-ios` checkout (`AppleSpeechLiveTranscriptionEngine.swift`,
`DspeechUITests.swift`, `.agent-*`, `docs/AUTOPILOT-JOURNAL.md`) was preserved and
untouched.

```bash
# on mac24, throwaway worktree at FETCH_HEAD = fd10aa0
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Dspeech.xcodeproj -scheme Dspeech \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
  -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
```

Result: **`** TEST SUCCEEDED **`** (full `DspeechTests` suite, incl. new
`LocalSpeakerIdentifierFactoryTests`). Throwaway worktree removed after; no litter.

## Acceptance gates covered (new tests)

- Pack absent/acquiring/failed/disabled → identifier unavailable (audio never
  dropped pre-ASR; the existing `SpeechAudioBufferGateTests` prove fail-open routing).
- Installed + matching fake backend classifies and **discards a confident pilot**
  segment (`factoryBackedPipelineDiscardsConfidentPilotBeforeASR`).
- Mixed speech stays transcribed (`factoryBackedPipelineKeepsMixedSpeechTranscribed`).
- Installed-without-backend keeps pipeline **not ready**
  (`installedWithoutBackendKeepsPipelineNotReady`).
- `localModelPath` round-trips through storage; legacy JSON decodes to `nil`.

## Next slice

1. Implement `FluidAudioSpeakerIdentifier: LocalSpeakerIdentifier` + a
   `FluidAudioBackendBuilder: LocalSpeakerBackendBuilder` that loads CoreML weights
   from `pack.localModelPath` (no registry auto-download), then pass that builder in
   `ContentView` and register it. Requires adding the `FluidAudio` SPM product and a
   pbxproj edit — do this in a cycle that can `xcodebuild` on mac24 to validate the
   project file.
2. Build the explicit `absent → downloading → installed` acquisition flow + the
   network-deny integration test from `docs/eval/local-speaker-model-pack-validation.md` §1.

---

## Closeout (docs-writer, run `dspeech-builder-20260525T070045Z-aac9d282`)

**Status:** DONE — merge-ready, no source changes outstanding. The speaker-identifier
factory/gate landed on `origin/feat/local-pilot-voice-filter` and is verified green at the
pushed tip. Shipping build is **inert/fail-open** (no registered backend → every path
transcribes); a confident pilot is discarded only behind an installed pack **and** an
available, dimension-matching backend — proven via a fake builder, no real model yet.

**Artifacts (canonical handoff):**
- Tester-unit verification: `docs/run-notes/2026-05-25-speaker-identifier-test.md` — full
  `DspeechTests` `** TEST SUCCEEDED **`, 44 slice tests green, deterministic (re-run ×2),
  fail-open contract table, no-network/privacy confirmation. Verdict: safe for supervisor.
- FluidAudio upstream contract: `docs/research/2026-05-25-fluid-audio-speaker-identifier-contract.md`.
- Eval contract: `docs/eval/local-speaker-model-pack-validation.md`.
- Prior pre-ASR routing-gate slice: `docs/run-notes/2026-05-24-pre-asr-routing-gate.md`
  (+ recovery artifacts under `.ai/runs/dspeech-supervisor-20260524T203001Z-b9f6965f-*.md`).

**Commits (on `origin/feat/local-pilot-voice-filter`, draft PR
[#2](https://github.com/daocism/dspeech/pull/2)):**
- `fd10aa0 feat(voice-filter): gate concrete speaker identifier behind installed model pack` — the slice code.
- `0fda374 docs(research): verify FluidAudio speaker-identifier upstream contract`.
- `49acd3a docs(run-notes): record speaker-identifier factory/gate slice`.
- `c81f97a docs(run-notes): tester-unit verification of speaker-identifier gate 49acd3a`.
- `35a69ae docs(ai): reconcile pre-asr routing gate recovery`.

**Blockers:** none for this slice. Forward-looking, before the FluidAudio backend can enable
discard in production (must clear, not optional):
- **W1 (MEDIUM):** `SpeechAudioBufferGate.route` is `@MainActor` — move classification
  off-main with guaranteed FIFO `request.append` ordering before a real (suspending) classifier.
- **W2 (MEDIUM):** discard is per-buffer — make it utterance/segment-aware so dropping pilot
  buffers can't fragment following non-pilot recognition.
- **T1 (LOW):** extract the `appendThroughGate` append-vs-skip branch into a pure helper
  testable without AVFoundation; the engine-level seam is currently unit-untested.
- **Host hygiene:** the canonical mac24 checkout `dspeech-ios` carries stale uncommitted WIP
  (HEAD `e024f20`) that *removes* the buffer-gate seam. Verification ran against the pushed
  tip in a throwaway worktree; the mac24 checkout must be reconciled to `origin` before any
  future build runs against it directly.

**What the supervisor should inspect:**
1. `docs/run-notes/2026-05-25-speaker-identifier-test.md` — the fail-open contract table and
   the single guarded discard path.
2. `git show fd10aa0` — `LocalSpeakerIdentifierFactory.make` returns `Unavailable` for every
   case except installed-pack + available, dimension-matching backend.
3. `DspeechTests/VoiceFilterTests.swift::LocalSpeakerIdentifierFactoryTests` (+ the existing
   `SpeechAudioBufferGateTests`) — the behavior pins guarding against silent ATC discard.
4. Confirm the next ADR-0008/FluidAudio builder clears W1/W2/T1 and runs on a mac24 checkout
   matching `origin` before enabling production discard.

**Notion:** active task `369dfa2b-7893-814c-be7e-e7cea26486a6`
(`https://www.notion.so/369dfa2b7893814cbe7ee7cea26486a6`): **Notion connector returned
NOT_FOUND for the active task** (matches the CEO preflight; no Notion connector is reachable
from this run environment), so the status update was **not applied**. Per `CLAUDE.md`, Notion
is a read-model only — this does not gate code. The repo artifacts and commit SHAs above are
the canonical handoff.
