# Run note — 2026-06-01 — live-ASR crash, locale, interleaved audio

Branch `fix/live-asr-locale-and-concurrency` off `feat/dspeech-mvp-integration`.
Full `DspeechTests` + `DspeechUITests` green on mac24 (iPhone 17 Pro / iOS 26.4),
`swift format lint --strict` clean tree, `gitleaks` clean. Two adversarial review
passes; all findings resolved.

## Commits

Base hygiene (on `feat/dspeech-mvp-integration`):
- `f5fe408` ci: concluded the in-progress merge of `fix/ci-xcode-select-portable`.
- `d322a2a` chore(format): conformed the whole tree to swift-format 6.3.0 (Xcode 26).
  The tree was lint-dirty under the current toolchain, so CI `lint-secret-scan` was
  red; it is green now.
- `829c2fc` fix(hooks): `.githooks/pre-commit` used the bash-4 `mapfile` builtin and
  aborted on macOS system bash 3.2 (`mapfile: command not found`) — replaced with
  portable `while read` loops.
- `6005a01` feat(test): committed the on-simulator SFSpeech probe harness.

Fixes (this branch):
- `befe50f` fix(asr): **live-tap actor-isolation crash**. The `AVAudioEngine` input
  tap ran on the RealtimeMessenger thread and hopped `@MainActor` work per buffer;
  under Swift 6 this tripped `swift_task_isCurrentExecutor -> dispatch_assert_queue_fail`
  (`EXC_BREAKPOINT`, crash `Dspeech-2026-05-29-104502.ips`). Now a nonisolated tap
  deep-copies each buffer and yields it to an ordered, `Sendable` `AsyncStream`; one
  `@MainActor` consumer drains it in FIFO capture order into the router/request. Also
  fixes the prior FIFO-reordering and recycled-buffer hazards. Removed dead
  `emitFinalSegment`.
- `79e4f5f` feat(asr): **configurable recognition locale**. The engine hardcoded
  `en-US`, so French (and other non-English) ATC produced garbage/empty transcripts.
  `RecognitionSettings` (persisted, `@Observable`) validates the locale against
  `SFSpeechRecognizer.supportedLocales`; default resolves from device languages with
  an English fallback; engine reads it via a provider at `start()`; SettingsView has a
  locale picker. Pure `RecognitionLocaleCatalog` logic unit-tested.
- `1d33bd1` test(asr): exhaustive ICAO phonetic-alphabet + segmenter coverage.
- `d8f0e5b` fix(asr): **interleaved PCM buffers**. `dspeechDeepCopy` / `monoFloatSamples`
  assumed deinterleaved float32; per-channel indexing on an interleaved buffer reads
  out of bounds and copies half the frames. External USB / line-in interfaces (the
  cockpit-cable path, ADR 0004) commonly present interleaved audio — this was silent
  corruption on the real input route. Both branch on `format.isInterleaved` now.

## Recognition validation (canonical, device-class)

SFSpeechRecognizer / SpeechAnalyzer do **not** run in the iOS Simulator (on-device
speech assets are not provisioned: `kLSRErrorDomain Code=300`; cloud fallback and
`SpeechAnalyzer.isAvailable` also fail there). Validated instead on the **macOS host**
(a real iOS-26-class engine) with Apple's `SpeechAnalyzer`/`SpeechTranscriber`:

- Full ICAO alphabet (en-US): **26/26**. Digits 0–9: **10/10** incl. "niner". A
  realistic synthesized ATC call transcribed perfectly.
- Two real French ATC desktop clips: **fr-FR accurate**, **en-US garbage/empty** —
  confirming the locale defect, now fixed.

Implication: the recognition pipeline is sound; **transcript assertions must run on a
real device or the host file API, never the Simulator.** A reusable host harness lives
at `/tmp/dspeech-transcribe` (not committed).

## Note on current-context priority #1

The "VAD / silence-gap utterance segmentation" item is in fact implemented:
`EnergySilenceSegmenter` cuts decision windows on a trailing-silence edge (or a
max-window cap), and is now unit-tested (`SpeechActivitySegmenterTests`). The residual
PTT-straddle risk (reviewer NOTE A) remains a property of the embedding over real
audio, not a router-seam gap.
