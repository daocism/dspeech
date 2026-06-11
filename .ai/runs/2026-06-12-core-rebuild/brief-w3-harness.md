# W3 — Harness round 1 (spec §4.1): `dspeech-replay transcribe` ASR runner

Read `.ai/runs/2026-06-12-core-rebuild/brief-common.md` first.

## Files you own

- `Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit/TranscribeCommand.swift` (new)
- `Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit/ReplayKitCommand.swift` (main-dispatch
  edit only: route `transcribe` subcommand; legacy eval invocation
  `dspeech-replay --fixtures ...` must keep working unchanged — CI calls it)
- New SYMLINK (relative, like the existing ones) in the same Sources dir:
  `ATCContextualVocabulary.swift -> ../../../../Core/ASR/ATCContextualVocabulary.swift`

This is an SPM macOS executable (`Dspeech/Tools/ReplayKit`, swift-tools 6.0,
platform .macOS(.v15)). Verify with `swift build` + manual runs from that directory.
No pbxproj. Do NOT touch the iOS app targets. Round 2 (assembler wiring + block output +
verify-primary-scenario.sh) is NOT yours — a later pass integrates the assembler; your
job is the REAL-ASR event runner it will plug into.

## Purpose

The mechanical definition-of-done gate: run the owner's real French ATC cockpit audio
through the REAL Apple ASR exactly as the app configures it, and emit the raw event
stream (partials/finals/restart markers with audio timestamps) that the
TransmissionAssembler will consume. ASR truth on macOS because on-device SFSpeech does
not run in the iOS Simulator.

## CLI (binding)

```
dspeech-replay transcribe --audio <wav> --locale fr-FR \
  [--callsign <raw>] [--simulate-restart <seconds, repeatable>] \
  [--replay-tail on|off] [--chunk-seconds 0.1] [--emit-partials on|off]
```

Output (stdout, one line per event, machine-parsable and human-readable):

```
EVENT partial  t=2.40  «Bonjour ton radar»
EVENT final    t=6.99  conf=0.48  interim=false  «Bonjour ton radar, prévois une petite attente…»
  SEG [  0.21-  0.63] conf=0.56 Bonjour
EVENT restart  t=4.00  replayedTailSeconds=1.0
```

`t=` is AUDIO time (seconds into the wav), derived from fed-sample count at the moment
the callback fires for restarts, and from `SFTranscriptionSegment`
timestamp/duration for finals (print per-segment SEG lines under each final). Round all
to 0.01s.

## Implementation requirements (all verified empirically on this Mac — follow exactly)

1. **Real pipeline mirror**: `SFSpeechAudioBufferRecognitionRequest` with
   `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`,
   `taskHint = .dictation`, `addsPunctuation = true`, `contextualStrings =
   ATCContextualVocabulary.strings(callSign: <--callsign value or nil>)` — the exact
   configuration of `AppleSpeechLiveTranscriptionEngine.installRecognition` (read it).
   `recognizer.defaultTaskHint = .dictation` too.
2. **Run-loop pumping is LOAD-BEARING**: callbacks never fire if the main thread blocks
   on a semaphore. Drive everything from the main thread with
   `RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))` in a loop
   with explicit completion flags + deadline (existing probe pattern; 120s hard cap).
3. **Authorization**: call `SFSpeechRecognizer.requestAuthorization` first; if not
   `.authorized`, exit 3 with a clear stderr message. (Already authorized on this Mac.)
4. **Audio feed**: read the wav via the existing `PCM16WAVAudioReader`, convert to
   `AVAudioPCMBuffer`s of `--chunk-seconds` (default 0.1) at the file's sample rate
   (16kHz mono fixtures), `request.append(buffer)` for each chunk, then `endAudio()`
   after the last chunk. Feed speed: as fast as the run loop allows (no real-time
   sleep) — on-device recognition handles it.
5. **--simulate-restart S** (repeatable): when the fed-sample count crosses S seconds,
   mirror the app's restart path: print the pending partial as
   `EVENT final ... interim=true` (this is the interim-commit semantics), then
   `request.endAudio()`, `task.cancel()`, print `EVENT restart`, create a NEW
   request+task (same config) and continue feeding. With `--replay-tail on` (default),
   keep a rolling last-1.0s buffer queue (mirror `AudioReplayTail` semantics: max 1.0s,
   max 96 buffers) and re-append it into the new request first; `off` skips the re-feed.
   Audio timestamps from the NEW task's SFTranscriptionSegments are relative to the new
   task's audio start — offset them by the audio time at which the new task began
   feeding (account for the replayed tail: its first sample corresponds to
   restartTime - tailSeconds).
6. **Termination**: after `endAudio`, wait for the final result or error; a 1110-class
   "no speech" error after a final is normal — print `EVENT done t=<total>` and exit 0.
   Real errors: stderr + exit 1.
7. Strict Swift 6 concurrency: the recognition callback is nonisolated — marshal events
   through `nonisolated(unsafe)` state guarded by main-thread-only access or an
   AsyncStream, same discipline as the app engine.

## Acceptance (run these yourself, paste output in your summary)

```bash
cd Dspeech/Tools/ReplayKit
swift build
swift run dspeech-replay transcribe \
  --audio ../../../DspeechTests/Fixtures/ATC/atc-2549.wav --locale fr-FR --callsign FGOAB
swift run dspeech-replay transcribe \
  --audio ../../../DspeechTests/Fixtures/ATC/atc-2551.wav --locale fr-FR \
  --simulate-restart 4.0 --replay-tail on
swift run dspeech-replay --fixtures ../../../DspeechTests/Fixtures/ReplayKit  # legacy still green
```

Expected: French text events for both fixtures (e.g. 2549 starts with phonetic letters
like "Golf Oscar…", 2551 with "Bonjour ton radar…"); restart run shows interim=true
final + restart marker + continued finals with correctly offset timestamps.
