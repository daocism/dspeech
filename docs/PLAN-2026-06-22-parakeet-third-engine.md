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

## Phase 1 — Hash manifest (LANDED 2026-06-23, resolved against HuggingFace)

Pinned revision and per-file SHA-256 manifest, ready to paste into
`ParakeetModelPackInstaller.swift`:

```
Repository:  FluidInference/parakeet-realtime-eou-120m-coreml
PinnedRev:   40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355
SubPath:     160ms/
TotalBytes:  224_031_731  (~213.65 MiB)
License:     nvidia-open-model-license
Language:    en (English-only)
Resolved:    2026-06-23
```

| File (relative to `160ms/`) | Size (bytes) | SHA-256 |
|---|---:|---|
| `streaming_encoder.mlmodelc/analytics/coremldata.bin` | 243 | `a981b257db79b4f86e6fa06a92562160a0ae71554746c24af24d8634b85f0356` |
| `streaming_encoder.mlmodelc/coremldata.bin` | 670 | `e762abc60d999bcd10aab985b68191a602f2e8e03165cf08671c60f93936037a` |
| `streaming_encoder.mlmodelc/metadata.json` | 5_327 | `75be31534cdd91711b08ba3a46046523eb9be9909618cd569cce1ea79e842a95` |
| `streaming_encoder.mlmodelc/model.mil` | 639_646 | `709f9280eb0bba1fd698cc252275ba802885c2c53cdb60d399277281dac09b5d` |
| `streaming_encoder.mlmodelc/weights/weight.bin` | 212_691_776 | `12cd781a4300b52b6687587b7d8e37e0ce5c8ccb1dbea036008275e6abf5070c` |
| `decoder.mlmodelc/analytics/coremldata.bin` | 243 | `3996975a8cbc1949159c55605b3132b39b2484f51acbd55d796d93c70de02b49` |
| `decoder.mlmodelc/coremldata.bin` | 497 | `c3ccbff963d8cf07e2be2bd56ea3384a89ea49628922c6bd95ff62e2ae57dc34` |
| `decoder.mlmodelc/metadata.json` | 3_283 | `0977480649f2756894b0acfe2fdf4231a991f25e3fe02562bfb71b65ca944575` |
| `decoder.mlmodelc/model.mil` | 7_409 | `b7c084a35bdbc887d69d6226cd533e2c11b2792c37d7352cf878f9f6f3c13555` |
| `decoder.mlmodelc/weights/weight.bin` | 7_873_600 | `0b4cacecdcd9df79ab1e56de67230baf5a8664d2afe0bb8f3408eefa972cb2f4` |
| `joint_decision.mlmodelc/analytics/coremldata.bin` | 243 | `5bca32ad130dcad6605cc00044c752aa5b45ef57d14c17f2d1a2fa49d6cf55b5` |
| `joint_decision.mlmodelc/coremldata.bin` | 493 | `22d4abc4625b935ee035b5f8ce7cb28d1041b9b01c12173e287bf4b5f5d99625` |
| `joint_decision.mlmodelc/metadata.json` | 3_181 | `e970ae87137730020690d24d971813db3633bbdfed602d43b6a9c84deced6dc8` |
| `joint_decision.mlmodelc/model.mil` | 9_608 | `45e8590bc87e34c162b547e43a4f60e64db15b017f48395d7835a6867884804f` |
| `joint_decision.mlmodelc/weights/weight.bin` | 2_794_182 | `7039b2010a269153f5a96edf28637f921a86ef8822f248f2d6712f7a6bce84b4` |
| `vocab.json` | 17_437 | `83fd42ad33dae1bd3ceee6c0bb6c625f314cf0b2dc8430be441ac1e2643d5c36` |

Reproduce / re-verify:

```bash
REV="40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"
BASE="https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/${REV}/160ms"
for f in <see table above>; do
  curl -fsSL -o "$f" "$BASE/$f"
  shasum -a 256 "$f"
done
```

`StreamingEouAsrManager.loadModels(from:)` only consumes the three `.mlmodelc`
bundles + `vocab.json` (the preprocessor was replaced by FluidAudio's native
Swift mel spectrogram). The `1280ms/` and `320ms/` subpaths are intentionally
excluded — ADR-0012 ships only the 160ms variant.

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

## What landed in this session (2026-06-22 → 2026-06-23)

- ✅ Phase 0 recon
- ✅ ADR-0012
- ✅ This PLAN doc
- ✅ Phase 1 hash manifest (all 16 files SHA-256 + sizes resolved against HF, pinned
  to revision `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`)
- ✅ Draft of `Dspeech/Core/ASR/ParakeetStreamingAdapter.swift` written to disk
  (NOT yet wired into the Xcode project — see handoff below).

## Handoff to user (BLOCKING, cannot proceed without)

The repo's steering extension blocks Claude from editing `project.pbxproj` while
Xcode is open (correctly — direct pbxproj edits while Xcode is running can crash
Xcode and corrupt the file). All file registration must happen via Xcode's UI.

**Action required from owner** (sequence below; ~3 minutes in Xcode UI):

1. Open `Dspeech.xcodeproj` in Xcode.
2. In the Project Navigator, expand `Dspeech > Dspeech > Core > ASR`.
3. Right-click the `ASR` group → `Add Files to "Dspeech"…`.
4. Navigate to `Dspeech/Dspeech/Core/ASR/` (relative to repo root) and select
   `ParakeetStreamingAdapter.swift`.
5. In the add-dialog: targets = **Dspeech only** (NOT the test targets), reference
   type = `Create groups`, NOT `Create folder references`. Confirm.
6. Verify the file shows up under `ASR` group and is added to the `Dspeech`
   target (check the right-pane Target Membership).
7. ⌘B to build — should still pass (the adapter is unreferenced from any other
   code at this point; it's library code waiting for the engine to import it).
8. Once green, commit the pbxproj change + the new Swift file together:
   `git add Dspeech.xcodeproj/project.pbxproj Dspeech/Core/ASR/ParakeetStreamingAdapter.swift`
   `git commit -m "feat(asr): add ParakeetStreamingAdapter (FluidAudio bridge)"`

After step 8, the next Claude session continues with:

- Commit 2.2 (engine): `ParakeetLiveTranscriptionEngine.swift` + tests, same
  add-to-Xcode dance for both files.
- Commit 2.3 (installer): `ParakeetModelInstaller.swift` + tests, with the hash
  manifest from Phase 1 already pasted in.
- Commits 3.1–3.2 (wiring): only existing files touched
  (`RecognitionSettings.swift`, `ContentView.swift`, `SettingsView.swift`,
  `Localizable.xcstrings`) — no pbxproj edits needed.

## What blocks Phase 2.2+ (engine code, installer code)

- ❌ Owner must perform the Xcode UI steps above for **every new Swift file**
  Claude writes (~5 files total, one batch per commit).
- ❌ For final installer verification, BuildProject + RunSomeTests must run
  AFTER the file is registered in Xcode. Until then, Claude's
  `XcodeRefreshCodeIssuesInFile` reports "file not found in project structure"
  (which is what blocked verification of the in-disk adapter today).
