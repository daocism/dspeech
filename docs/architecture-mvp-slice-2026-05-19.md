# Architecture — MVP-completion slice, 2026-05-19

Frozen interface contract for waves W2–W5 of `docs/PLAN-2026-05-19.md`. Closes
PRD gates F3 (translation), F5 (audio source), first-run, Settings sheet, F2
polish. Implementers build only against the protocols below.

## Source-of-truth read (cited)

- `docs/PLAN-2026-05-19.md:11-17` — gap list; `:36-62` DAG; `:97-107` W7 gate.
- `docs/product/prd-ios-mvp.md:30-44` — F3 toggle, audio picker, first-run cards;
  `:48-57` — F1–F8 acceptance.
- `docs/adr/0002-privacy-local-only-default.md:15-26` — local-only default,
  no silent cloud, on-device-only translation in default mode.
- `Dspeech/Core/Settings/PrivacySettings.swift:27-75` — storage-protocol +
  `@MainActor @Observable` template every new settings type copies.
- `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:12-24` — event/stream seam.
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:76-80` —
  `AVAudioSession(.record, mode: .measurement)`; the audio session is shared.
- `Dspeech/App/ContentView.swift:152-160` — `showTranslation` toggle is local
  view state today; F3 binds it to a real service. `:210-266` Settings is one
  Privacy section; F5/Translation/About sections are added by W5.

## API verification (Context7-equivalent)

The Context7 MCP (`mcp__plugin_context7_context7__*`) is not mounted in the mac24
headless agent env. Per the anti-hallucination rule's "fetch current docs" branch
(`CLAUDE.md`), every Apple symbol below was verified against Apple's official DocC
JSON (`developer.apple.com/tutorials/data/documentation/...json`), 2026-05-19:

- **Translation** (`documentation/translation*`): framework iOS 17.4+;
  `TranslationSession`/`LanguageAvailability`/`TranslationError` programmatic API
  iOS 18.0+ (runs on the iOS 26 target).
  `TranslationSession.init(installedSource:target:)` throws, installed-only;
  `func translate(_ String) async throws -> Response`;
  `func translations(from:[Request]) async throws -> [Response]`;
  `func prepareTranslation() async throws`;
  `LanguageAvailability.init()`,
  `func status(from:Locale.Language,to:Locale.Language?) async -> Status`,
  `var supportedLanguages: [Locale.Language] { get async }`;
  `Status` = `.installed | .supported | .unsupported`;
  `TranslationError` = `nothingToTranslate, unableToIdentifyLanguage,
  internalError, alreadyCancelled, notInstalled, unsupportedSourceLanguage,
  unsupportedTargetLanguage, unsupportedLanguagePairing`;
  `TranslationSession.Configuration(source:target:)` `Equatable`, used by the
  SwiftUI `.translationTask(_:action:)` modifier.
- **AVAudioSession** (`documentation/avfaudio/avaudiosession/*`):
  `var availableInputs: [AVAudioSessionPortDescription]?` (iOS 7+);
  `func setPreferredInput(_ AVAudioSessionPortDescription?) throws` (iOS 7+,
  call after category/mode set + session active, confirm via `currentRoute`);
  `class let routeChangeNotification: NSNotification.Name` (iOS 6+, posted on a
  **secondary thread**), userInfo `AVAudioSessionRouteChangeReasonKey` /
  `…PreviousRouteKey`; `RouteChangeReason` = `newDeviceAvailable,
  oldDeviceUnavailable, override, categoryChange, routeConfigurationChange`;
  `Port` constants `builtInMic, headsetMic, usbAudio, bluetoothHFP` confirmed.
  `.measurement` (system signal-processing off) is correct for receive-only ATC;
  `.voiceChat` (two-way VoIP AGC/echo) would mangle it — keep `.measurement`.
- **Speech** (`documentation/speech/*`): `SFSpeechRecognizer` **not deprecated**
  in iOS 26 (`deprecated:false`); `requiresOnDeviceRecognition` /
  `supportsOnDeviceRecognition` still valid — the existing engine wiring stays
  correct on iOS 26, untouched this slice. **Delta:** iOS 26 adds
  `SpeechAnalyzer` (actor) + `SpeechTranscriber` + `AssetInventory` as the modern
  lower-latency on-device path. Out of scope here (dispatch: do not touch the
  engine); recorded as a follow-up spike for a later F1 latency ADR.

## ADR 0002 determination — F3 is KEPT, no deferral ADR

Apple `Translation` runs inference **on-device**. First-time language assets
download only through Apple's **system-presented UI** (`.translationTask` /
`prepareTranslation()`); `init(installedSource:target:)` throws when assets are
absent, and `LanguageAvailability.status == .installed` is the gate. No
Dspeech-originated networking exists on this path, so "zero `URLSession` in
`Core/Translation/`" (PLAN W7) is satisfiable, and cockpit audio/transcripts
never leave the device — only Apple's OS-level model fetch, the same class as the
keyboard/dictation model and the `language-pack-spec.md` "metadata for software
updates" carve-out. Therefore the Translation framework **satisfies ADR 0002**:
F3 stays in the MVP gate; **no `0007-translation-feature-deferral` is written**.
The keep-decision is ADR-worthy; per PLAN it is W9 docs-writer's
`docs/adr/0007-translation-framework-on-device.md` — its Decision text is this
section. (Repo ADRs live in `docs/adr/`, not the dispatch's `docs/adrs/` typo.)

## Component graph

```
                 ┌──────────────── App / SwiftUI (W4a, W5) ───────────────┐
                 │ ContentView      SettingsSheet      FirstRunView        │
                 │   │ showTranslation   │ Audio/Translation/About  │ cards│
                 ▼   ▼                   ▼                          ▼      │
        LiveTranscriptionVM  TranslationOverlayVM  AudioLevelMeterVM  FirstRunVM
         (exists)             (W2a)                 (W3a)             (W4a)
                 │                   │                    │              │
   ┌─────────────┼───────────────────┼────────────────────┼──────────────┼────┐
   │  CORE (Sendable protocols — frozen here, W1)                              │
   │  LiveTranscriptionEngine   TranslationService          AudioInputService   │
   │  (exists, untouched)       TranslationLanguagePack-     FirstRunCoordinator │
   │                            Preparer                     FirstRunStateStore  │
   └──────┬──────────────────────────┬───────────────────────────┬─────────────┘
          ▼                          ▼                            ▼
  AppleSpeechLive…Engine    AppleTranslationService        AVAudioSession adapter
  (exists)                  (W2a; imports Translation)     (W3a; imports AVFAudio)
                            PackPreparer at SwiftUI seam    UserDefaults stores
                            (W2a/W5; .translationTask)      (W3a/W4a; PrivacySettings
                                                            storage template)
```

PrivacyMode is read by `TranslationOverlayVM`/its factory: under `.localOnly`
only `TranslationService` (installed-only) is constructed and the pack CTA is the
sole acquisition route; there is no cloud MT type in this slice (ADR 0002 §Conseq).

## Data flow per gate

- **F1 ASR (unchanged):** `AppleSpeechLiveTranscriptionEngine.events()` →
  `LiveTranscriptionViewModel.segments` → `ContentView`. No change this slice.
- **F2 polish:** view-only; transcript stays ≥17 pt monospaced, dynamic-type,
  dark mode (`ContentView.swift:357-396`). No protocol.
- **F3 translation:** finalized `TranscriptSegment` → `TranslationOverlayVM`
  calls `availability(translatingFrom:into:)`. `.installed` →
  `translate(_:from:into:)` → gloss line set on the segment row; ASR is never
  awaited/blocked (translation runs on its own `Task`). `.downloadable` → emit
  the "Download pack — N MB" CTA → user tap → `prepareLanguages(from:into:)`
  (Apple system sheet) → re-query. `.unsupported` → inline "pair unavailable",
  ASR continues. Source = `Locale.Language(identifier:)` from
  `segment.sourceLanguageCode`; target from the (W2a) `TranslationSettings`.
- **F5 audio source:** Settings audio page → `availableInputs()` →
  `AudioInputDescriptor` list (3 `AudioInputKind` buckets). Tap → `select(_:)`.
  Page visible → `levels()` drives the "Test level" bar via
  `AudioInputLevel.normalized`. `routeChanges()` re-lists on USB-C plug/pull.
  Selection persisted per device by W3a's `AudioSourceSettings` (PrivacySettings
  storage template, `Codable` `AudioInputDescriptor`).
- **First-run:** `DspeechApp`/`ContentView` (W5) asks
  `FirstRunCoordinator.currentState()`. `.showing(card)` → `FirstRunView`;
  `advance()` / `skip()` → `.completed` persists via `FirstRunStateStore`. No
  account/email/analytics (PRD §1.3:45).

## Error propagation

Fail-fast, one boundary per surface (`CLAUDE.md`): protocols use **typed
throws** (`throws(TranslationServiceError)` / `throws(AudioInputServiceError)` /
`throws(FirstRunCoordinatorError)`), never `Optional`/`{ok:false}` for failures.
Adapters map Apple errors → these enums at the adapter edge; each view model is
the single catch boundary, logs context, and renders a **non-blocking** message
(capture/ASR never silently stop — PLAN guard 3, `audio-input-matrix.md`). No
mid-pipeline `try?`/`catch{ return nil }`. `currentInput()` returning `nil` is
pre-configuration *state*, explicitly not an error path.

## Threading (Swift 6.0 now; Swift 6.2 approachable-concurrency aware)

Project is `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
nonisolated-by-default. All three service protocols are `: Sendable` with `async`
methods (or `Sendable`-element streams), so isolation is explicit and stays
correct if the project later adopts Swift 6.2 `defaultIsolation(MainActor.self)`
("approachable concurrency") where bare protocols would become `@MainActor`.
Adapters do AVAudioSession/Translation work off the main actor; the
`routeChangeNotification` (Apple: secondary thread) handler hops to the picker
VM's actor. View models follow the `PrivacySettings` template: `@MainActor
@Observable final class` consuming `Sendable` services/stores. `AsyncStream` /
`AsyncThrowingStream<_, Error>` match the existing
`AudioCaptureService`/`SpeechRecognitionService` seam exactly.

## Test seams (for W2b/W3b/W4b)

- All three protocols are trivially fakeable (no Apple import in Core): fake
  `TranslationService` returning each `TranslationLanguageStatus`/error;
  fake `AudioInputService` yielding scripted `availableInputs`,
  `AsyncThrowingStream` levels, and `routeChanges`; in-memory `FirstRunStateStore`.
- New persistent settings get a UserDefaults round-trip test, like
  `PrivacySettingsTests.userDefaultsRoundTrip` (`CLAUDE.md` rule).
- `FirstRunCoordinator` is a pure state machine over `FirstRunCard.allCases` —
  Swift Testing `@Test` exhaustively (advance×3 → `.completed`; `skip` from each
  card; persistence-failure path throws `.persistenceUnavailable`).
- Property test target: `AudioInputLevel.normalized` is monotonic in
  `averagePowerDB` and bounded to `0...1` (fast Swift Testing parameterized).
- UI: every new control needs an `accessibilityIdentifier` (PLAN W7);
  XCUITest IDs `translation-download-cta`, `audio-source-picker`,
  `audio-level-meter`, `first-run-card-{1,2,3}`, `first-run-skip`.

## Frozen files (this commit)

`Dspeech/Core/Translation/TranslationServiceProtocol.swift`,
`Dspeech/Core/Audio/AudioInputServiceProtocol.swift`,
`Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift`, plus append-only
`project.pbxproj` registration (CLAUDE.md-sanctioned; no existing ID renumbered;
`plutil -lint` OK; `xcodebuild … build` SUCCEEDED). Implementers must not edit
these signatures; signature changes route back through W1.

## Implementer guidance / open items

- Dir naming: protocols are frozen at `Core/Translation/`, `Core/FirstRun/`
  (this dispatch). PLAN row text said `Core/Onboarding/` + `TranslationService.swift`
  — implementers align concretes to the **protocol locations above**
  (`AppleTranslationService.swift` in `Core/Translation/`, stores in
  `Core/FirstRun/`); flagged in `docs/handoff.md`.
- W2a: `AppleTranslationService` uses `init(installedSource:target:)` for the
  installed path; `TranslationLanguagePackPreparer` is the only type allowed to
  drive `.translationTask`/`prepareTranslation()` and lives at the SwiftUI seam
  (W2a model + W5 stitch), still zero Dspeech `URLSession`.
- W3a: resolve `AudioInputDescriptor.portType` back to a live
  `AVAudioSessionPortDescription` via `availableInputs` `uid` match before
  `setPreferredInput`; share the one `AVAudioSession` with the ASR engine.
- W9: write `docs/adr/0007-translation-framework-on-device.md` from the
  "ADR 0002 determination" section above.
