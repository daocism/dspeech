# Handoff — researcher-web → engineer

Run: `dspeech-builder-20260523T115550Z-4fea767f`
Slice: audio route health validation kit (pre-ASR)
Branch: `feat/local-pilot-voice-filter`
Deliverable: `docs/research/2026-05-23-audio-route-health.md`

## Sources used (all accessed 2026-05-23)

- https://developer.apple.com/documentation/AVFAudio/AVAudioSessionPortDescription — verbatim body (input/output `portType` set, properties incl. `hasHardwareVoiceCallProcessing`)
- https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioHardwareRouteChanges/HandlingAudioHardwareRouteChanges.html — verbatim body (route-change reasons, `AVAudioSessionRouteChangeReasonKey`, `AVAudioSessionRouteChangePreviousRouteKey`, recommended pause-on-`OldDeviceUnavailable` rule)
- https://developer.apple.com/library/archive/qa/qa1799/_index.html — verbatim body (Bluetooth HFP bidirectional routing via `setPreferredInput:error:`)
- https://developer.apple.com/documentation/avfaudio/responding_to_audio_route_changes — canonical URL; JS-rendered, only `<title>` available
- https://developer.apple.com/documentation/avfaudio/avaudiosession/1616493-routechangenotification — canonical URL; JS-rendered
- https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp — canonical URL; JS-rendered
- https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest — canonical URL; JS-rendered
- https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/addspunctuation — canonical URL; JS-rendered

## Decision summary

- Build a **route-health classifier** as a pure function over snapshot
  structs. Five health states: `suitableExternal`, `cautionBuiltIn`,
  `unsuitableOutputOnly`, `unknownExternal`, `noInput`.
- Put `AVAudioSession` behind `protocol AudioSessionRouting`. The
  classifier and view-model take this protocol by initializer
  injection; the only file allowed to `import AVFAudio` is the live
  adapter.
- Route changes during a live session: pause ASR (not raw capture) on
  `.oldDeviceUnavailable`; recompute health silently on `.override`,
  `.categoryChange`, `.wakeFromSleep`, `.routeConfigurationChange`,
  `.unknown`; surface a toast on `.newDeviceAvailable`; stop cleanly
  on `.noSuitableRouteForCategory`. Inverts the Apple "playback pause"
  rule appropriately for a capture app.
- Source audio file remains canonical for debugging; the transcript is
  advisory and carries route-health metadata at start + every change.

## Exact recommendations for the engineer

1. New domain types (no Apple imports):
   - `RouteSnapshot { inputs: [PortSnapshot], outputs: [PortSnapshot] }`
   - `PortSnapshot { portType: String, portName: String, uid: String, hasHardwareVoiceProcessing: Bool }`
   - `enum RouteHealth { suitableExternal, cautionBuiltIn, unsuitableOutputOnly, unknownExternal, noInput }`
   - `enum RouteChangeEvent { newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, wakeFromSleep, noSuitableRouteForCategory, routeConfigurationChange, unknown }`
2. `RouteHealthClassifier.classify(route:availableInputs:) -> RouteHealth` — pure.
3. `protocol AudioSessionRouting` with `currentRouteSnapshot`,
   `availableInputSnapshots`, `routeChanges: AsyncStream<RouteChangeEvent>`,
   `requestRecordPermission()`, `setPreferredInput(uid:)`.
4. `LiveAudioSessionRouting` (real adapter) and
   `FakeAudioSessionRouting` (tests). Live is the sole `AVFAudio`
   importer.
5. Capture-screen chip + route-change banner per §2.1/§2.2 of the
   research doc. Mandatory copy: "input route" / "capture source"; no
   "radio link" / "certified".
6. Persist `inputHealthAtStart`, `portType`, `portName` on the
   transcript metadata (no UID). Insert "route change" markers in the
   transcript timeline at change timestamps.
7. Tests required: classifier unit tests over JSON fixtures
   (`tests/Fixtures/AudioRoute/*.json`), one view-model integration
   test driven by `FakeAudioSessionRouting` per `RouteHealth` value,
   one banner test for `.oldDeviceUnavailable` simulated via the fake.

## Constraints (do not violate)

- No network, no cloud calls, no new ASR backend.
- No hardware-purchase requirement — reviewer must run unit tests with
  iOS Simulator only.
- Single source of `AVFAudio` import (the live adapter).
- No certification or aviation-regulatory language anywhere in UI copy.

## Uncertainty parked for a real device / later research

- BluetoothLE (LE-Audio) as a Dspeech input — behavior varies across
  third-party headsets; classify as `suitableExternal` only when iOS
  actually reports it under `currentRoute.inputs`.
- Aviation-headset vendor/model recognition by `portName` — out of
  scope this slice.
- `airPlay` as input — treat as `unknownExternal` until a real user
  hits it.
- `hasHardwareVoiceCallProcessing` preference policy — parked.
- Exact Swift enum-case spelling for `AVAudioSession.RouteChangeReason`
  under current Swift SDK — the engineer must verify against the
  installed iOS SDK; the research doc uses the documented forms
  (`AVAudioSessionRouteChangeReasonNewDeviceAvailable` etc. as the
  Objective-C constants; `.newDeviceAvailable` etc. as the Swift
  cases) but final symbol shape is whatever the compiler accepts.
- Several developer.apple.com pages are JavaScript-rendered and could
  not be quoted verbatim in this session (listed above as "canonical
  URL; JS-rendered"). Verbatim grounding came from Apple's archive
  (the Audio Session Programming Guide and QA1799) and from the one
  reference page that did return body
  (`AVAudioSessionPortDescription`).

## Worker_done payload

- `output_path`: `docs/research/2026-05-23-audio-route-health.md`
- `sources_count`: 8 (3 with verbatim body, 5 canonical-URL-only)
- `citations_count`: 8
- `confidence`: medium-high
- `open_questions_count`: 5
