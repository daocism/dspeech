# ADR 0009 — Speech stack: SFSpeechRecognizer, not SpeechAnalyzer (for now)

Date: 2026-06-11. Status: accepted.

## Context

iOS 26 ships the WWDC25 SpeechAnalyzer/SpeechTranscriber stack: long-form, on-device,
system-managed models (AssetInventory), explicitly positioned as the successor to
SFSpeechRecognizer (which is NOT deprecated in the iOS 26 SDK). Dspeech is iOS 26-only,
continuous-listening — on paper the ideal SpeechTranscriber adopter. The 2026-06-11
production-readiness research verified the current contracts.

## Decision

Stay on SFSpeechRecognizer for the live ATC engine this iteration.

The deciding constraint: **SpeechTranscriber does not honor contextual-string biasing**
(`AnalysisContext.contextualStrings` is consumed only by `DictationTranscriber`).
Callsign + ICAO-phraseology biasing is a core product requirement — the configured
callsign is the highest-value proper-noun hint the recognizer gets, and the engine now
seeds both written and spoken forms. Secondary factors: the engine's hardened lifecycle
(restart taxonomy, replay tail, availability delegate) is SFSpeechRecognizer-specific and
device-verified; SpeechTranscriber is unavailable on the Simulator, weakening the CI lane;
the iOS 26 convenience input-conversion APIs arrive only in the iOS 27 beta.

## Migration path (revisit at iOS 27)

`DictationTranscriber` DOES honor contextualStrings and `ContentHint
.customizedLanguage(modelConfiguration:)` custom LMs — it is the modern target that keeps
biasing. Re-evaluate when: (a) iOS 27 input-conversion conveniences ship, (b) a device
eval shows DictationTranscriber ≥ SFSpeechRecognizer accuracy on the ATC replay corpus,
(c) the capability source unification (OnDeviceLocaleResolver) is already aligned to
whatever engine runs — keep it that way.

## Consequences

- OnDeviceLocaleAvailability intersects SpeechTranscriber's on-device list with
  SFSpeechRecognizer support so the offered locales always match the engine in use.
- The one-minute/utterance recycling model stays (restart taxonomy + replay tail own it).
- A future engine swap is contained behind LiveTranscriptionEngine.
