# PLAN 2026-06-22 — Parakeet EOU as third ASR engine (multi-commit implementation)

Status: IN PROGRESS (Phase 0 + ADR landed; engine + installer + UI wiring pending follow-up sessions)
ADR: `docs/adr/0012-parakeet-streaming-third-asr-engine.md`
Owner: AI (Claude Opus 4.7)

## Why a written PLAN exists

The work is multi-commit and multi-session. The PLAN lets each session pick up exactly
where the previous left off, prevents relitigation of decisions captured in the ADR,
and forces atomic-commit hygiene (one concept per commit, every commit green).

Each commit below is **atomic, behavior-preserving** until the final wiring commit. The
order is chosen so the build stays green and the tests stay green after every commit;
the engine code is in tree before the UI exposes it, with full test coverage, but is
unreferenced from product code paths until the wiring commit.

## Phase 0 — Recon (LANDED, 2026-06-22)

- ✅ Verified FluidAudio pin `8048812869b0c7c6fa393e564a4fb6f95126ba23` ships the Parakeet
  EOU streaming API: `public protocol StreamingAsrManager`, `public final class StreamingEouAsrManager`,
  `loadModels(from:)` for offline manual load, `setPartialTranscriptCallback`, `setEouCallback`.
- ✅ Confirmed the model is **English-only** (LibriSpeech-trained Parakeet EOU 120M).
  Multilingual Parakeet TDT exists but is sliding-window batch, not streaming.
- ✅ Confirmed FluidAudio default cache lives at
  `~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/<repo>/`.
- ✅ ADR-0012 documents the architectural decision (this PLAN's parent).

## Phase 1 — Hash manifest prerequisite (BLOCKING, requires network)

**Cannot land any code in Phase 2+ without this.** The pinned manifest requires:

1. Resolve the current HEAD revision SHA of `FluidInference/parakeet-realtime-eou-120m-coreml`
   from HuggingFace.
2. Download all files under the `160ms/` subpath at that revision.
3. Compute per-file SHA-256 hashes.
4. Record (revision, file list, sizes, hashes) into the new
   `ParakeetModelPackInstaller.swift` `ExpectedModelFile` constants.

The CLI commands (run from a network-enabled host):

```bash
REV=$(curl -s https://huggingface.co/api/models/FluidInference/parakeet-realtime-eou-120m-coreml \
        | jq -r '.sha')
echo "Pinned revision: $REV"
mkdir -p /tmp/parakeet-pin
cd /tmp/parakeet-pin
# Discover files under 160ms/ subpath at that revision (HF API)
curl -s "https://huggingface.co/api/models/FluidInference/parakeet-realtime-eou-120m-coreml/tree/$REV/160ms" \
  | jq -r '.[] | .path'
# Download each (or use git lfs clone with revision checkout)
# For each file F:
#   curl -L "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/$REV/$F" -o "$F"
#   shasum -a 256 "$F"
#   stat -f '%z' "$F"   # file size
```

**Acceptance criterion for Phase 1:** A populated `expectedModelFiles: [ExpectedModelFile]`
array with hashes is ready to paste into `ParakeetModelPackInstaller.swift`. Total expected
download size is calculated and recorded.

**Until Phase 1 is complete, Phase 2+ MUST NOT proceed.** Hardcoded fake hashes are
explicitly banned by CLAUDE.md hard rule #3 (no placeholders).

## Phase 2 — Engine code (4 commits, atomic, behavior-preserving)

### Commit 2.1 — `feat(asr): add Parakeet streaming protocol + FluidAudio adapter`

**Files:**
- `Dspeech/Core/ASR/ParakeetStreamingAdapter.swift` (new, ~80 lines)
  - Defines `protocol ParakeetLiveStreaming: Sendable` mirroring our project's
    abstraction style (`func loadModels(from folderURL: URL) async throws`,
    `func appendAudio(_ buffer: AVAudioPCMBuffer) throws`,
    `func processBufferedAudio() async throws`,
    `func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void)`,
    `func setEouCallback(_ callback: @escaping @Sendable (String) -> Void)`,
    `func reset() async throws`, `func cleanup() async`).
  - `actor SystemParakeetStreamingAdapter: ParakeetLiveStreaming` wrapping
    `FluidAudio.StreamingEouAsrManager` (initialized with `.parakeetEou160ms.createManager()`).
- `DspeechTests/ParakeetStreamingAdapterContractTests.swift` (new, ~80 lines)
  - Property tests verifying the adapter forwards every protocol call to the underlying
    manager (using a recording-spy stub for `FluidAudio.StreamingAsrManager`).

**Why atomic & safe:** new files only; no existing file touched; no behavior reachable
from product code paths (no caller exists yet).

### Commit 2.2 — `feat(asr): add ParakeetLiveTranscriptionEngine (LiveTranscriptionEngine impl)`

**Files:**
- `Dspeech/Core/ASR/ParakeetLiveTranscriptionEngine.swift` (new, ~350 lines)
  - `@MainActor final class ParakeetLiveTranscriptionEngine: LiveTranscriptionEngine`
  - Init takes: `transcriber: any ParakeetLiveStreaming`,
    `installedModelFolderURL: @MainActor () -> URL?`,
    `localeProvider: @MainActor () -> String?`,
    `arbiter: AudioCaptureArbiter = .shared`,
    `audioSession: any LiveAudioSessionManaging = SystemLiveAudioSession()`,
    `authorizer: any LiveSpeechAuthorizing = AppleLiveSpeechAuthorizer()`,
    `bufferGate: (any SpeechAudioBufferGate)? = nil`.
  - Lifecycle: status state machine, mic permission, `loadModels(from:)`,
    capture-conduit subscription, partialCallback forwarding to `events()` AsyncStream,
    EOU finalization (with `bufferGate?.route(...)` for voice-filter classification),
    cleanup.
  - **Locale gate** in `start()`: if `localeProvider()` is not nil and does not start with
    `"en"`, status = `.failed("parakeet-requires-english-locale")`; never starts.
  - **Model-not-installed** in `start()`: if `installedModelFolderURL()` returns nil,
    status = `.failed("parakeet-model-not-installed")`.
- `DspeechTests/ParakeetLiveTranscriptionEngineTests.swift` (new, ~400 lines)
  - Lifecycle tests parallel to `AppleSpeechLiveTranscriptionEngineLifecycleTests` and
    `WhisperKitLiveTranscriptionEngineTests`: start/stop/reset, partial-on-callback,
    final-on-EOU, voice-filter gate integration on EOU, locale-gate rejection of every
    non-`en-*` locale, model-not-installed failure path, cleanup on stop.
  - Uses `FakeParakeetStreaming` (a stub conforming to `ParakeetLiveStreaming`) so tests
    never touch real FluidAudio.
- Build: green. All 875+ existing tests + new ParakeetLiveTranscriptionEngine tests
  green.

**Why atomic & safe:** new files only; not yet referenced from any product code (the
`TranscriptionEngineChoice` enum still has only `.apple` and `.whisperKit`); tests
prove the engine works without exposing it.

### Commit 2.3 — `feat(asr): add ParakeetModelPackInstaller (pinned revision + SHA-256 manifest)`

**Files:**
- `Dspeech/Core/ASR/ParakeetModelPackInstaller.swift` (new, ~250 lines)
  - Mirrors `Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift` structure.
  - `static let sourceRevision = "<from Phase 1>"`.
  - `static let expectedModelFiles: [ExpectedModelFile] = [<from Phase 1>]`.
  - `static let stagedFolderURL` resolves to `Application Support/FluidAudio/Models/parakeet-realtime-eou-120m-coreml/160ms/`.
  - Reuses `WhisperKitModelFileDownloading` interface from
    `WhisperKitModelInstaller.swift` for the per-file pinned-URL download contract
    (or a new `ParakeetModelFileDownloading` if interfaces diverge; prefer reuse).
  - Integrity verification (computed-vs-expected SHA-256, throws on mismatch with the
    `integrityChecksumMismatch` error case mirrored from `ModelPackInstallError`).
- `DspeechTests/ParakeetModelPackInstallerTests.swift` (new, ~250 lines)
  - Mirrors `Dspeech/DspeechTests/WhisperKitModelInstallerTests.swift` patterns:
    pinned-URL construction, checksum-mismatch detection, disk-space taxonomy,
    cancellation, idempotent install detection.

**Why atomic & safe:** the installer is self-contained; not yet referenced from
controllers or UI.

### Commit 2.4 — `feat(asr): add ParakeetModelInstallController orchestrating install state`

**Files:**
- `Dspeech/Core/ASR/ParakeetModelInstallController.swift` (new, ~150 lines)
  - `@MainActor @Observable final class ParakeetModelInstallController` parallel to
    `Dspeech/Core/VoiceFilter/ModelPackAcquisitionController.swift`.
  - Wraps `ParakeetModelPackInstaller`; emits `.absent`/`.acquiring(progress)`/`.installed`/`.failed`
    states; persists state through a `ParakeetModelStateStorage` protocol (UserDefaults default).
- Tests: lifecycle tests parallel to `ModelPackAcquisitionControllerTests`.

**Why atomic & safe:** controller is self-contained; not yet wired to UI.

## Phase 3 — Wiring (2 commits, behavior-preserving until UI commit)

### Commit 3.1 — `feat(settings): add TranscriptionEngineChoice.parakeet (storage + factory)`

**Files:**
- `Dspeech/Core/Settings/RecognitionSettings.swift` — add `.parakeet` to the enum.
- `Dspeech/App/LiveTranscriptionViewModel.swift` — extend the engine-instantiation
  switch with a `.parakeet` arm (returns the new `ParakeetLiveTranscriptionEngine` with
  `installedModelFolderURL` wired to `ParakeetModelInstallController.installedFolderURL`).
- `Dspeech/App/DspeechApp.swift` (and/or composition root) — instantiate the
  `ParakeetModelInstallController` alongside the existing model controllers.
- Tests: storage round-trip for `.parakeet`; forward-only migration (older
  `.apple`/`.whisperKit` still load; unknown value falls back to `.apple`).
- Build green; no UI surface yet.

**Why atomic & safe:** the enum case exists, but the picker still doesn't show it (UI
update is the next commit). Selecting `.parakeet` programmatically would work but no
code path can do so yet.

### Commit 3.2 — `feat(settings-ui): expose Parakeet engine in picker (English-only gate)`

**Files:**
- `Dspeech/App/SettingsView.swift` — extend the engine picker section:
  - Parakeet entry appears only when `recognition.localeIdentifier?.hasPrefix("en") == true`.
  - When the recognition locale is not English, the entry is hidden (NOT greyed-out —
    a hidden option avoids misleading the user about a configuration that won't apply).
  - Standard model-install affordance pattern (parallel to WhisperKit install UI):
    "Install Parakeet (English, ~XX MB)" with progress; "Installed" with size + delete.
- Localized strings: `Localizable.xcstrings` additions for the new picker entry,
  install CTA, install-progress states, error messages.
- Tests: XCUITest update — engine picker visibility test for both English and
  non-English locales.

**Why atomic & safe:** this is the only commit that changes user-visible behavior.
By this point the engine, installer, and controller are all in tree with green tests;
this commit just makes them reachable.

## Phase 4 — Validation (1 commit)

### Commit 4.1 — `test(harness): extend verify-primary-scenario with parakeet engine arm`

**Files:**
- `scripts/verify-primary-scenario.sh` — extend to run a third engine arm on English
  fixtures (the script already runs both Apple and WhisperKit).
- `scripts/run-asr-eval.py` — extend to invoke the Parakeet engine when present.
- `scripts/testdata/voice-corpus.json` — confirm English fixtures cover Parakeet's
  capability surface (callsign anchoring, noise floor, EOU detection).

**Why atomic & safe:** harness-only changes; product code already shipped in Phase 3.

## Phase 5 — Knowledge base & process (1 commit, docs only)

### Commit 5.1 — `docs(ai-kb): record three-engine roster + Parakeet validation results`

- `docs/ai-kb/current-context.md` — "Three-engine roster" paragraph summarizing the
  default policy (Apple), the multilingual selectable (WhisperKit), the English-only
  selectable (Parakeet), and the empirical WER on the English fixture subset.
- Update `docs/ai-kb/README.md` if it indexes ADRs.

## Atomic-commit checklist (applies to every commit above)

- [ ] One concept per commit; commit message body explains the why.
- [ ] `BuildProject` returns no errors.
- [ ] All previously-green tests stay green.
- [ ] New tests added for new behavior; PBT where pure functions are involved.
- [ ] No `try?` swallowing a meaningful error.
- [ ] No fake API calls — every FluidAudio symbol grep-confirmed against the pinned
      checkout at `~/Library/Developer/Xcode/DerivedData/<hash>/SourcePackages/checkouts/FluidAudio`.
- [ ] No placeholders, no "Coming soon", no `TODO`/`FIXME`/`fatalError(` (CLAUDE.md
      hard rule #3 + the angle-bracket guard).
- [ ] Commit-message body cites this PLAN file and the ADR.
- [ ] After commit: push immediately to `feat/parakeet-third-engine` branch.

## Open questions (DEFER to during-implementation)

1. **Does Parakeet's per-segment confidence integrate cleanly with our `requiresVerification`
   gate (TranscriptSegment.confidence < 0.82)?** FluidAudio's streaming partial callback
   yields text only; the final ASRResult carries `confidence: Float`. Phase 2.2 must
   wire confidence from the EOU-finalized result onto the emitted segment.
2. **Does the EOU callback fire while a previous decode is still in flight?** Adapter
   tests in Phase 2.1 must verify whether we need a re-entrancy guard around partial
   emission and whether the EOU classifier's debounce (~640ms default) is sufficient.
3. **Does the user-visible engine name need to mention "English only" inline or only on
   the install affordance?** Defer to design review during Phase 3.2.
4. **Should we ship the 320ms variant as a "high accuracy / slightly higher latency"
   option in a future wave?** Out of scope for this PLAN; revisit after Phase 4
   validation results.

## What landed in this session (2026-06-22)

- ✅ Phase 0 recon
- ✅ ADR-0012
- ✅ This PLAN doc

## What blocks Phase 2 (engine code)

- ❌ Phase 1 hash manifest — requires network to HuggingFace + ~5 file downloads
  + shasum computation. Cannot be done in a sandboxed session.

When Phase 1 completes, all subsequent phases are mechanical multi-commit work
following this PLAN.
