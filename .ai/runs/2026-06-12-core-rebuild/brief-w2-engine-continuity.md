# W2 — Engine continuity (spec §2): interim commit at every task boundary

Read `.ai/runs/2026-06-12-core-rebuild/brief-common.md` first.

## Files you own

- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`
- `Dspeech/Core/ASR/AppleSpeechEngineSupport.swift` (only if you need a pure helper there)
- `DspeechTests/AppleSpeechLiveTranscriptionEngineLifecycleTests.swift`

No new files, no pbxproj changes.

## The defect you are fixing (D-1, owner hit it on a real iPhone)

Spoken text appears, a 1-2s pause triggers the benign no-speech (1110) restart path:
`restartRecognition()` calls `task?.cancel()` — a cancelled SFSpeechRecognitionTask
delivers NO final, so the live partial the user was reading is never committed; the next
task's partials then REPLACE it on screen. The Stop path already commits the pending
partial (`LiveTranscriptionViewModel.commitPartialAsSegment`, flag
`isStopCommittedPlaceholder`); the RESTART path must do the analogous commit INSIDE the
engine.

## Required behavior (spec §2.1, §2.3 — binding)

1. Track the latest non-empty partial text of the CURRENT recognition task (update it
   where the callback yields `.partial`; clear it when a real final for that task is
   emitted and when a new task installs).
2. At EVERY recognition-task boundary, BEFORE the old task is cancelled/replaced —
   `restartRecognition(recognizer:)`, the task replacement inside
   `handleEngineConfigurationChange()`, and the terminal-failure paths that run
   `cleanup()` while a partial is pending (`handleTermination` `.fail`,
   `handleRecognizerAvailabilityChange`, restart-loop-guard `.fail`) — if the tracked
   partial is non-empty:
   - emit `.segment` with a `TranscriptSegment` built from the partial: trimmed text,
     `confidence: 0`, `sourceLanguageCode` derived from the active locale (reuse
     `Self.sourceLanguageCode(for:)`), `source: .liveATC`,
     `isInterimRestartCommit: true`;
   - clear the tracked partial.
3. After the interim commit, for restart/rebuild boundaries (NOT terminal failures),
   emit `.taskRestart` so downstream (TransmissionAssembler) can distinguish a task
   recycle from silence. Order: `.segment(interim)` → `.taskRestart` → new task installs.
4. The user-facing invariant (§2.3): no event path may cause previously displayed text
   to shrink. The interim commit is what guarantees it across recycles.
5. Stop path stays as is (VM owns the Stop commit; do NOT double-commit on stop —
   `stop()`/`cleanup()` via `stop()` must NOT emit an interim commit, the VM already
   handles it; clear the tracked partial in cleanup).
6. Replay tail: add an init parameter `replayTailEnabled: Bool = true`; when false the
   engine skips `replayTail.append` and the re-feed loop in `installRecognition`. This is
   the seam for the §2.2 empirical on/off comparison — default behavior unchanged.

## Tests (extend the lifecycle tests file; use the existing DEBUG seams —
`installRecognitionCallbackConduitForTesting`, `emitRecognitionCallbackForTesting`,
`primeListeningForTesting`; add a narrowly-scoped new seam only if genuinely required)

- partial → restart boundary ⇒ events contain `.segment` with
  `isInterimRestartCommit == true` and text == partial, followed by `.taskRestart`.
- partial → real final for same task ⇒ NO interim commit afterwards on next restart
  (tracked partial cleared by the final).
- empty/whitespace partial ⇒ no interim commit, but `.taskRestart` still emitted on
  restart boundaries.
- terminal failure with pending partial ⇒ interim commit emitted BEFORE the
  `.failed` status event.
- §2.3 monotonic pin: scripted sequence of partials/finals/restarts (mix interim commits
  and real finals) ⇒ concatenation of all `.segment` texts in emission order is
  monotonically non-decreasing in length, and no event ever instructs removal
  (structurally: assert the event stream contains only append-semantics events; assert
  every emitted partial is either finalized or interim-committed by the time its task
  generation ends).
- `replayTailEnabled: false` ⇒ no buffer re-feed on restart (observable via the existing
  test seams or a counter exposed in DEBUG).

Note: the engine file is 787 lines, hard limit 800 — if your changes push it past,
move pure helpers into `AppleSpeechEngineSupport.swift`.
