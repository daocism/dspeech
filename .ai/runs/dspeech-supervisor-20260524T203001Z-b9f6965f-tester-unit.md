# Verification — pre-ASR routing gate recovery

- **Run ID:** `dspeech-supervisor-20260524T203001Z-b9f6965f`
- **Role:** tester-unit (verification-only; no production code edited)
- **Date:** 2026-05-24
- **Notion run:** `36adfa2b-7893-8188-a257-dd401d67f84a`
- **Verdict:** ✅ **PASS** — `origin/feat/local-pilot-voice-filter` head verified green.

## Commit under test

- **HEAD tested:** `75d1be928273714428111108519df2dbaa054b17`
  (`75d1be9 docs(run-notes): record pre-asr routing gate commit sha`)
- Pre-ASR gate commits confirmed present:
  - `24dfbdf feat(voice-filter): gate apple speech buffers before asr` — confirmed
    ancestor of HEAD (`git merge-base --is-ancestor 24dfbdf HEAD` → true).
  - `75d1be9 docs(run-notes): record pre-asr routing gate commit sha` — is HEAD.
- The prior builder run (`dspeech-builder-20260524T190024Z-0f54bfce`) was marked
  `Blocked`, but its two commits are present and healthy on the pushed branch head.

## mac24 verification

Deterministic shell only (no Claude dispatched to mac24). The shared mac24 checkout
`/Users/andre/projects/dspeech-ios` had an unrelated dirty tree (see caveat), and its
incoming commits modify the same `AppleSpeechLiveTranscriptionEngine.swift` that is
locally modified there — so `git merge --ff-only` would have been **destructive**.
To avoid clobbering in-progress local work, the suite was run in a throwaway detached
git worktree at the exact pushed commit, then removed.

- **Setup:** `git worktree add --detach /tmp/dspeech-verify-b9f6965f 75d1be9`
  (HEAD `75d1be9` confirmed in worktree).
- **Command:**

  ```bash
  cd /tmp/dspeech-verify-b9f6965f && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Dspeech.xcodeproj -scheme Dspeech \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" \
    -only-testing:DspeechTests CODE_SIGNING_ALLOWED=NO
  ```

- **Destination:** `platform=iOS Simulator, name=iPhone 17 Pro, OS=26.4`
  (device `32AF0651-C9D5-4A80-BB1E-5FFD62B75DF0`, confirmed available).
- **Result:** `** TEST SUCCEEDED **`
- **Cleanup:** `git worktree remove --force /tmp/dspeech-verify-b9f6965f && git worktree prune`.

### Suites executed (all green)

`ATCTranscriptGateTests`, `CallSignTests`, `CaptureCoordinatorTests`,
`LiveTranscriptionViewModelTests`, `ModelPackStateStorageTests`, `PrivacySettingsTests`,
`RouteHealthClassifierTests`, `RouteHealthMonitorTests`, `SpeakerMatcherTests`,
**`SpeechAudioBufferGateTests`** (the new pre-ASR gate suite), `TranscriptSegmentTests`,
`VoiceFilterPipelineTests`, `VoiceFilterStorageTests`.

`SpeechAudioBufferGateTests` cases observed passing include:
`confidentPilotIsDiscardedBeforeASR`, `nonPilotTranscribes`, `mixedTranscribes`,
`unavailableIdentifierFailsOpenToASR`, `thrownClassifierErrorFailsOpenToASR`,
`insufficientSpeechFailsOpenToASR`, `routeBeforeTranscriptionFailsOpenForInsufficientSpeech`,
`monoFloatSamplesExtractsMonoFloat32`, `monoFloatSamplesAveragesStereoChannels`,
`monoFloatSamplesNilForEmptyBuffer`, `monoFloatSamplesNilForNonFloatFormat`.

Acceptance coverage confirmed: route-health, capture-coordinator, model-pack, callsign,
and voice-filter suites all remained green alongside the new gate suite.

## Static checks (from the verification worktree at `75d1be9`)

1. Network / model-download surfaces
   (`URLSession|Network.framework|NWPathMonitor|http(s)://|ModelRegistry|FluidAudio|WhisperKit|dataTask`):
   - Production `Dspeech/`: **no network/model-download code**. The only match is a
     `// Phase 2 will replace …` comment in
     `Dspeech/App/LiveTranscriptionViewModel.swift:67` naming the future FluidAudio
     classifier — prose, not a network surface.
   - `DspeechTests/`: only `https://mirror.invalid/voice-filter` model-pack-source
     **test fixtures** (intentionally invalid, no real I/O).
   - `docs/run-notes/`: source-citation URLs and "no FluidAudio/network added" prose —
     non-blocking per mission.
2. Certification / flight-safety copy
   (`certif|guarantee|flight-safe|safety-critical|radio link|tower link|FAA|EASA`):
   - Production `Dspeech/`: **none**.
   - `DspeechTests/`: matches are **forbidden-word guard lists** in
     `CaptureCoordinatorTests` and `RouteHealthMonitorTests` that *assert production copy
     avoids* these terms.
   - `docs/run-notes/`: prose documenting the absence of such claims.

   ✅ No new production network/model-download dependency or certification/flight-safety
   copy was introduced.

## mac24 dirty-tree caveat (preserved, not modified)

`/Users/andre/projects/dspeech-ios` carries pre-existing local work, left untouched:

- Modified (tracked): `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`,
  `DspeechUITests/DspeechUITests.swift`.
- Untracked: `.agent-logs/`, `.agent-prompts/`, `.agent-state/`, `docs/AUTOPILOT-JOURNAL.md`.
- Branch position there: `feat/local-pilot-voice-filter` at `e024f20`, **behind 4** of
  `origin`. This was **not** advanced — an `--ff-only` merge would have clobbered the
  local edits to `AppleSpeechLiveTranscriptionEngine.swift` (same file the incoming
  commits touch). Verification was isolated in a throwaway worktree instead; the dirty
  tree is byte-for-byte as found before and after.

## Residual risks

- Verification ran on iOS Simulator (`iPhone 17 Pro`, OS 26.4), not on physical
  cockpit/wired-audio hardware. The gate is pure-logic/unit-level; real audio-route
  behavior on device is out of scope for this run (ADR 0004 hardware path untested here).
- `DspeechUITests` (XCUITest) were not run (`-only-testing:DspeechTests` per mission;
  unit suite is the gate). The XCUITest target is also locally modified on mac24.
- The shared mac24 checkout remains 4 commits behind `origin` with uncommitted work in
  the ASR engine file; whoever owns that work must reconcile it against the merged
  pre-ASR gate changes before it lands.
