# 2026-06-02c — F1 live ASR silent-failure: root cause, fix, and the verification gap that let it ship

## Incident
Shipped to Andrei's iPhone as a "fully working MVP". On device: tap mic → button
flashes to listening (red) for ~1 s → drops back to idle with **no message, no
transcript**. The single core capability (F1 live on-device transcription) did not work
at all, and failed **silently**.

## Root cause (in `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`)
Four defects, all in the recognition lifecycle:
1. **Silent failure (CRITICAL).** The `recognitionTask` completion handler discarded its
   `error` (`else { event = nil }`) and converted any terminal-by-error into a benign
   `status = .stopped`. `.stopped` renders no message (only `.failed` does), so a real
   recognizer fault looked identical to "idle, just haven't spoken yet". Violated the
   repo's #1 rule (no silent failures).
2. **Session not sustained (CRITICAL, the actual trigger).** A single `SFSpeechRecognitionTask`
   was created and never replaced. An on-device task finalizes on the first utterance end
   / silence timeout (kAFAssistantErrorDomain 1110), so within ~1 s of ambient silence the
   one task ended and the engine tore the whole session down to `.stopped`. Continuous
   live transcription was impossible by construction.
3. **`supportsOnDeviceRecognition` never checked.** `requiresOnDeviceRecognition = true`
   (privacy: local-only) errors immediately if the locale's on-device asset is absent.
4. **No input-format guard** before `installTap` (0 Hz / 0-channel routes throw deep in
   CoreAudio).

## Why it escaped (the process failure — this is the important part)
Every gate was a **proxy**, never the real capability on the real target:
- unit tests drive `LiveTranscriptionViewModel` with a **FakeEngine** — they prove the
  view-model reacts to events, never that the engine produces them;
- build+test ran on the **iOS Simulator**, which **cannot run on-device Speech** at all;
- "F1 live ASR (real mic)" was parked in a **user-facing checklist** — i.e. the core
  verification was offloaded to Andrei's tap.
So nothing ever ran the real `SFSpeechRecognizer` / `AVAudioEngine` on real hardware. A
green suite certified the plumbing around F1 while F1 itself was untouched. Fleet memory:
`feedback_verify_primary_capability_on_real_target` (global).

## ADDENDUM — the silent-failure fix REVEALED/INTRODUCED a hard crash (installTap), now fixed
During device verification the app began **crashing on every mic tap** (`Crash: Dspeech at
<external symbol>`). Ground truth came from a Simulator crash report
(`~/Library/Logs/DiagnosticReports/Dspeech-*.ips`), NOT from guessing:
`+[NSException raise:format:]` → `AUGraphNodeBaseV3::CreateRecordingTap` →
`-[AVAudioNode installTapOnBus:bufferSize:format:block:]`. **Root cause:** `installTap`
was given a separately-read `outputFormat(forBus:0)`; when that ≠ the node's live
hardware/render format it aborts on `required condition is false: format.sampleRate ==
hwFormat.sampleRate`. Triggers: Simulator output-vs-render mismatch; on device,
`AVAudioSession` mode `.measurement` reconfigures the hw sample rate so a pre-`start()`
cached format is stale. **Fix (61fb383):** pass `format: nil` to `installTap` (uses the
bus's own current format — no mismatch) at BOTH crash sites —
`AppleSpeechLiveTranscriptionEngine` and `AVAudioEngineInputLevelMeter`. Verified on the
Simulator: the meter test reproduced the abort and now passes. Method lesson banked in
global memory `feedback_ios_crash_debugging_methodology`. The earlier "reorder task before
engine" change was a wrong guess (reverted-in-effect); the real fix is the tap format.
Continuous-flight requirement (one tap → whole flight) is satisfied by the sustained
session (mic+tap stay up; recognition task recycled per utterance/1110).

## ADDENDUM 2 — the ACTUAL mic-tap crash: a `@MainActor` tap closure missing `@Sendable`
The `format:nil` change (addendum 1) fixed the input-level METER abort, but the **ASR mic
tap still crashed every time**. I got the real cause by reproducing on the **Simulator**
(skip-permission test seam → `AppleSpeechLiveTranscriptionEngine` audio path) and reading
the symbolicated backtrace:
```
dispatch_assert_queue_fail ← swift_task_isCurrentExecutor
  ← <startEngine installTap closure (AVAudioPCMBuffer, AVAudioTime)>
  ← AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform
```
**Root cause:** the engine is `@MainActor`, so the bare `installTap { buffer, _ in … }`
closure inherited `@MainActor` isolation. AVFAudio invokes it on its realtime
`RealtimeMessenger` thread → Swift asserts `isCurrentExecutor(MainActor)` → false →
`dispatch_assert_queue_fail` (EXC_BREAKPOINT) on the FIRST captured buffer. It was LATENT
until the session-sustain fix kept the tap installed long enough for a buffer to arrive
(before, the tap was torn down within ~1 s). Proof: the meter tap (a non-`@MainActor`
type) never crashed; `CallsignDictationService`'s tap already had `@Sendable`; the ASR tap
was the only one missing it. **Fix:** mark the tap block `@Sendable` so it's nonisolated
and legally runs off-MainActor (it only captures the Sendable continuation). Verified on
the Simulator: buffers now flow through the realtime tap (`route #0 → appended #0 → …`)
with no crash; the suite is green. Lesson banked: `feedback_ios_crash_debugging_methodology`
(an AVAudioEngine tap/realtime callback on a `@MainActor` type MUST be `@Sendable`).

## Fixed in this change
- **Engine lifecycle rewrite**: `installRecognition` separated from `startEngine`; on a
  clean final / benign no-speech the task is **restarted while the mic+tap keep running**
  (session sustained); genuine errors surface as `.failed("asr-error: <domain>#<code> …")`;
  `supportsOnDeviceRecognition` guard → `.failed("on-device-model-missing: <locale>")`;
  input-format guard → `.failed("start-failed: …")`; a **generation token** ignores
  callbacks from superseded/cancelled tasks.
- **`CallsignDictationService`** (same silent-failure class, HIGH): recognition error now
  surfaces as `.unavailable("Не удалось распознать речь: …")` instead of silent `.idle`;
  1110 treated as a clean end.
- **`AudioSourceController.select`** (HIGH): `setPreferredInput` no longer `try?`-swallowed
  — applied first, UI/persistence reflect only OS-accepted selection; rejection surfaces
  via `selectionError` (shown in Settings, id `audio-source-error`).

## New tests — `DspeechTests/OnDeviceSpeechRecognitionTests.swift` (DEVICE-ONLY)
The tests that should have existed. They no-op on the Simulator and must run on a physical
device: `xcodebuild test -destination 'platform=iOS,id=<UDID>' -only-testing:DspeechTests/OnDeviceSpeechRecognitionTests`.
- `recognizerReportsOnDeviceSupportForActiveLocale` — asserts `supportsOnDeviceRecognition`
  for en-US + device locale (the exact missing-asset condition).
- `onDeviceRecognitionTranscribesSynthesizedSpeech` — AVSpeechSynthesizer → real on-device
  recognizer, asserts a non-empty transcript (or records the exact NSError).
- `liveEngineSustainsListeningThroughSilenceOnDevice` — drives the real engine, asserts it
  is still `.listening` after 4 s of silence (this is the F1 regression that used to fail
  in ~1 s; needs no acoustic input).

## Institutional gate (do not regress)
Simulator-green is **insufficient** for F1 / F5 / dictation. CI/verification must add a
**device lane** that runs `DspeechTests` on a physical device before any "works on device"
claim. `xcodebuild test` on a free Personal Team needs the phone **unlocked** (first run
copies shared-cache symbols — minutes, not a hang; do not kill early).

## Backlog — known issues NOT yet fixed (tracked, not silently dropped)
From the 3-agent escape audit (`wf_61ad46ee`). Severity = user-visibility of a regression.
- MEDIUM `LiveTranscriptionViewModel.maybeTranslate` catch-all swallows non-pack
  `TranslationServiceError` (engineFailure / unsupported pairing) → segment silently
  un-glossed with no reason. Add a `translationError` reason.
- MEDIUM `ContentView` `.translationTask` catch is empty — a real prepare/download failure
  is indistinguishable from user-cancel. Set `translationUnavailable` on genuine failure.
- MEDIUM `InputLevelMeter` `AVAudioEngine.start()` throw dropped → meter reads silent-0
  instead of "couldn't start". Surface a sentinel/error.
- MEDIUM `VoiceFilterStorage` / `ModelPackState` decode failure of a *present* blob is
  coerced to empty/.absent (corrupt == "never enrolled"/"never downloaded"). Distinguish
  absent vs corrupt; re-verify or surface.
- LOW `classifierUnavailable` routing reason is produced but consumed nowhere (voice-filter
  silently shows-all). Plumb a transient indicator.
- Device-only modes not yet handled: `AVAudioSession.interruptionNotification` +
  `mediaServicesWereResetNotification` observers; stop on route → `.noInput` /
  `.noSuitableRoute` (not only `.lost`).
- Missing device/integration tests still owed: F8 background-stop on hardware; real
  `AppleTranslationService` + `prepareTranslation` (Translation framework DOES run in the
  Simulator); FluidAudio model-pack download + enrollment; audio-source `setPreferredInput`
  against the real session; the Start-button happy-path XCUITest (currently only passes via
  the Simulator failure branch).
