# Local pilot voice filter run note — 2026-05-22

Source prompt: Open WebUI chat `b1a660d7-d521-48cf-af54-35268d0d56ae`, AI Office run `f1abcd97-137f-43ba-a935-26d01dab747a` (ended Blocked after two worker failures). Mr.Dao recovered the prompt and finished the core policy layer on `feat/local-pilot-voice-filter`.

## Implemented core behavior

- Pilot enrollment now stores both the local voiceprint vector and optional spoken aircraft callsign (`PilotVoiceProfile.spokenCallSign`).
- Pre-transcription routing is explicit: pilot voice is discarded before STT; non-pilot and mixed/low-confidence segments are kept for STT so ATC is not hidden.
- Speaker matching now distinguishes confident pilot, non-pilot, mixed/ambiguous, and insufficient speech.
- ATC transcript gate suppresses pilot readbacks, displays non-pilot callsign hits, keeps short dispatcher continuation windows, and exposes an `ATCVoiceIndicator` for UI badges such as dispatcher-addressed-own-callsign.
- Callsign matching handles compact tail numbers and ICAO phonetic forms.

## Current technical boundary

This is still a protocol-first core implementation. The real FluidAudio/CoreML embedding backend and the enrollment/settings UI are not wired yet. `UnavailableLocalSpeakerIdentifier` remains the default build adapter until the FluidAudio SPM/model integration lands.

## Verified

- mac24 `/tmp/dspeech-voice-filter-verify` test run:
  `xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4" CODE_SIGNING_ALLOWED=NO -quiet test`
- Result: full visible Dspeech unit-test suite passed, including `VoiceFilterPipelineTests/enrollmentStoresPilotVoiceAndSpokenCallSign`, `routeBeforeTranscriptionDiscardsPilotBeforeSTT`, `LiveTranscriptionViewModelTests/voiceFilterSuppressesNonMatchingCallSignSegments`, and `LiveTranscriptionViewModelTests/voiceFilterDisplaysOwnCallSignSegments`.

## Primary-source refresh

- FluidAudio GitHub README checked 2026-05-22: Swift SPM package `https://github.com/FluidInference/FluidAudio.git`, current README says speaker diarization, speaker embedding extraction, VAD, open-source models with permissive licenses; repo LICENSE is Apache-2.0.
- FluidAudio tests/source expose `DiarizerManager.extractSpeakerEmbedding(from:)` returning 256-dimensional embeddings and speaker pre-enrollment APIs.

## Next implementation step

Integrate FluidAudio as the concrete `LocalSpeakerIdentifier`, bundle/pin/download models under explicit local-only UX, then wire `routeBeforeTranscription` into the audio path before Apple Speech ASR.
