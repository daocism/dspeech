# W4 — French phonetics layer (spec §6.3) + transmission-level classifier (spec §3.4/§6.2)

Read `.ai/runs/2026-06-12-core-rebuild/brief-common.md` first.

## Files you own

- `Dspeech/Core/VoiceFilter/PhoneticCallsignParser.swift`
- `Dspeech/Core/VoiceFilter/CallSign.swift`
- `Dspeech/Core/VoiceFilter/TransmissionClassifier.swift` (new)
- `DspeechTests/PhoneticCallsignParserTests.swift`
- `DspeechTests/CallSignTests.swift`
- `DspeechTests/TransmissionClassifierTests.swift` (new)
- pbxproj registration ONLY for the two new files. Assigned IDs:
  - `A00000000000000000000940` fileRef + `A00000000000000000000941` buildFile for
    TransmissionClassifier.swift (app target Sources phase `A00000000000000000000018`,
    group `VoiceFilter` — the group containing VoiceFilterPipeline.swift).
  - `A00000000000000000000942` fileRef + `A00000000000000000000943` buildFile for
    TransmissionClassifierTests.swift (test target Sources phase
    `A00000000000000000000021`, group `DspeechTests`).

Note: `CallSign.swift` is symlinked into `Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit/`
and compiled there for macOS too — keep it dependency-free (Foundation only). After your
change run `cd Dspeech/Tools/ReplayKit && swift build` to prove the tool still compiles.
Symlink `TransmissionClassifier.swift` into that same Sources dir (relative symlink like
the existing ones) — the harness needs it on macOS. It must therefore also be
Foundation-only. Its dependencies need symlinks in the same dir too — create them:
`Transmission.swift -> ../../../../Core/Models/Transmission.swift` and
`TranscriptSegment.swift -> ../../../../Core/Models/TranscriptSegment.swift` (both are
Foundation-only).

## Part 1 — French phonetics (spec §6.3)

The fixtures are French ATC; the parser tables are English-only today, so a French
spoken callsign ("fox golf oscar alpha bravo" works, but digits "sept"/"huit" and
"unité" do not).

- Add a locale-aware layer to `PhoneticCallsignParser`: new entry point
  `parse(_ spoken: String, localeIdentifier: String?)` keeping the existing `parse(_:)`
  behavior for nil/en. For French language codes (`fr`, any region): additionally map
  digit words `zéro→0 un→1 deux→2 trois→3 quatre→4 cinq→5 six→6 sept→7 huit→8 neuf→9`,
  variant `unité→1`, and treat `décimale`/`virgule` as ignorable separator tokens (they
  mark the decimal in frequencies, never part of a callsign). Diacritic-fold tokens
  before lookup (`zéro` and `zero` both hit) — fold with
  `.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: en_US_POSIX)`
  like `ATCTranscriptGate.containsUrgencyBroadcast`.
  ICAO letter words stay international (already in the table).
  Beware: French tokens must NOT change behavior of the nil/en path (locale-gated layer,
  not a global table merge — English "six" already maps; the conflict-free overlap is
  fine inside the fr layer).
- `CallSign`: read the file first; thread the locale through whatever internal use of
  the parser exists (`matches(in:)`/`matchesAbbreviated(in:)` likely normalize spoken
  text). Add locale-aware variants with `localeIdentifier: String?` defaulting to nil so
  every existing call site compiles unchanged.
- Tests: mirror the existing English property/unit tests for the French layer
  (PhoneticCallsignParserTests + CallSignTests): full French phonetic callsign,
  mixed letters+French digits, diacritics stripped (`zéro`/`zero`), `unité`,
  `décimale` ignored, en path unaffected by fr-only words ("sept" must NOT map without
  the fr locale), French spoken callsign matches in French ATC sentence via CallSign.

## Part 2 — TransmissionClassifier (spec §1, §3.4, §6.2)

Pure, stateful-only-for-continuation struct that classifies a WHOLE transmission. This
replaces fragment-level gate semantics for the main screen (the old inverted D-2
behavior). It does NOT modify ATCTranscriptGate (untouched, other surfaces still use it).

```swift
struct TransmissionClassifierConfig: Equatable, Sendable {
  var continuationWindowSeconds: TimeInterval  // default 8
  static let `default`: TransmissionClassifierConfig
}

struct TransmissionClassifier: Sendable {
  init(
    config: TransmissionClassifierConfig = .default,
    configuredCallSign: CallSign?,
    localeIdentifier: String?,
    voicePackActive: Bool,
    otherCallSignDetector: (@Sendable (String) -> Bool)? = nil
  )

  mutating func classify(
    text: String,
    speakers: [SpeakerMatchDecision],
    endedAt: Date
  ) -> TransmissionClassification
}
```

Decision order (first match wins), using `TransmissionClassification` from
`Core/Models/Transmission.swift`:

1. Urgency phrase anywhere in text (reuse `ATCTranscriptGate.containsUrgencyBroadcast`)
   → `.displayed(.urgencyBroadcast)`; refresh continuation anchor.
2. Configured callsign matches anywhere in text — full or abbreviated, via the
   locale-aware CallSign matching from Part 1 → `.displayed(.callSignMatch)`; refresh
   continuation anchor.
3. Voice evidence (only when `voicePackActive`): aggregate `speakers` over the
   transmission — if a majority of non-`insufficientSpeech` decisions are confident
   `.pilot`, → `.filtered(.pilotVoice)`; if a majority are `.nonPilot`,
   → `.displayed(.nonPilotVoice)`. (Read `SpeakerMatchDecision` in SpeakerMatcher.swift
   for the exact cases; `mixed` counts as neither.)
4. No callsign configured AND no voice pack: nothing can anchor dispatcher-ness →
   `.displayed(.noAnchorConfigured)` (honest fallback — the UI shows a one-time hint).
5. `otherCallSignDetector` fires on the text → `.filtered(.addressedToOther)`.
6. Within `continuationWindowSeconds` of the last urgency/callsign anchor
   (`endedAt - lastAnchor <= window`) → `.displayed(.continuationOfRecentCall)`
   (does NOT refresh the anchor).
7. Otherwise → `.filtered(.nonRelevant)`.

Empty/whitespace-only text → `.displayed(.insufficientEvidence)` (fail open, never
silently drop).

Tests: one per rule + order-of-precedence cases (urgency beats pilot voice; callsign
beats addressed-to-other; continuation does not refresh itself — two consecutive
continuation-window transmissions where the second falls outside the original anchor
window must be `.filtered(.nonRelevant)`), French callsign anchoring with fr locale,
honest-fallback rule, empty text rule.
