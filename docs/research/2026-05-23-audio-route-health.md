# Audio Route Health — Validation Kit for Cockpit/Radio Input

Run: `dspeech-builder-20260523T115550Z-4fea767f`
Branch: `feat/local-pilot-voice-filter`
Author role: `researcher-web`
Status: design-input for engineer slice, no implementation here.

## TL;DR

Before Dspeech starts ASR for an ATC/cockpit session, the app must
classify the active `AVAudioSession` input route and surface a
"route health" state to the user. Classification is a pure function
over `AVAudioSessionPortDescription` snapshots and can be unit-tested
without hardware. The session adapter (the part that talks to
`AVAudioSession`) sits behind a protocol so route classification logic
is exercised from fixture snapshots, and live behavior is verified on
device later. No certification claim is implied — we only call out
whether the OS reports a plausible external capture path.

This slice does not buy hardware, does not add a network dependency,
and does not change the existing Speech recognition path. It adds
visible signal before listening starts and a defined reaction when the
route changes mid-session.

## 1. Route taxonomy for Dspeech

Source for input-capable port constants: Apple's
`AVAudioSessionPortDescription` reference page lists `portType` values
with input/output semantics. Verbatim WebFetch (2026-05-23) returned
the following input-port list: `headsetMic`, `builtInMic`, `lineIn`,
`usbAudio`, `bluetoothHFP`, `bluetoothLE`, `carAudio`, `airPlay` (airplay
input requires a configured route); and the output-only list:
`bluetoothA2DP`, `builtInSpeaker`, `headphones`, `HDMI`. Source:
[AVAudioSessionPortDescription](https://developer.apple.com/documentation/AVFAudio/AVAudioSessionPortDescription)
(accessed 2026-05-23).

For Bluetooth specifically, Apple's archived QA1799 confirms
HFP is bidirectional and selecting a Bluetooth HFP input via
`setPreferredInput:error:` automatically also routes audio output to
the same HFP device; A2DP is output-only and never appears as an input
route. Source:
[QA1799 Selecting microphones with AVAudioSession](https://developer.apple.com/library/archive/qa/qa1799/_index.html)
(accessed 2026-05-23). Quote: *"If an application uses the
`setPreferredInput:error:` method to select a Bluetooth HFP input, the
output will automatically be changed to the Bluetooth HFP output."*

Mapping to Dspeech route-health classes (project-defined enum):

| Health | Concrete `portType` examples | Rationale |
|---|---|---|
| `suitableExternal` | `lineIn`, `usbAudio`, `headsetMic` (wired), `bluetoothHFP` when the device name suggests aviation gear, `carAudio` | External capture path; the user picked something that is not the iPhone body mic. Most likely a headset, intercom tap, or USB audio interface from a radio. |
| `cautionBuiltIn` | `builtInMic` | Works for testing and offline transcription but picks up cabin noise; we say so. |
| `unsuitableOutputOnly` | route contains zero `inputs` OR only `bluetoothA2DP` is connected and the user paired audio with no mic | The OS will fall back to `builtInMic`; surface that fallback explicitly so the user is not surprised. |
| `unknownExternal` | input `portType` is not in the documented Apple set | Treat as caution; record `portType` raw value for diagnostics. |
| `noInput` | `availableInputs` is empty or `currentRoute.inputs` is empty | Block "Start listening" with a clear reason. |

Notes:

- We never claim a given route is a "certified radio link". Even a
  USB audio interface plugged into a real airband receiver is, from
  iOS's perspective, just `usbAudio`. The route signal is necessary,
  not sufficient.
- `bluetoothLE` LE-Audio support is real on recent iOS but device
  behavior varies; classify as `suitableExternal` only when the OS
  reports it as an actual input on `currentRoute.inputs`, otherwise it
  is irrelevant (LE-Audio output-only headphones still show up as
  output ports).
- `airPlay` as input is rare; treat as `unknownExternal` until we see
  a real-world example.

## 2. Recommended app behavior

### 2.1 Before listening starts

Compute `RouteHealth` from `AVAudioSession.sharedInstance().currentRoute`
and render a status chip in the capture screen:

- `suitableExternal` — green dot, label `"Input: <portName>"`. No
  blocker.
- `cautionBuiltIn` — amber dot, label `"Input: iPhone microphone"` and
  one-line hint `"Plug in a headset or radio tap for cleaner audio."`
  Do not block.
- `unsuitableOutputOnly` / `unknownExternal` — amber, label `"Input
  fallback active"` and a Settings → Bluetooth deep-link hint. Allow
  starting but mark the resulting session's transcript metadata with
  `inputHealthAtStart`.
- `noInput` — red, disable the Start button with reason `"No audio
  input available"`.

Persist `inputHealthAtStart`, `portType`, and `portName` (no UID, that
is per-device PII-adjacent) into the session's metadata so the replay
view can show the user later why a recording was noisy.

### 2.2 During a live listening session

Subscribe to `AVAudioSession.routeChangeNotification`. The
notification's `userInfo` carries:

- `AVAudioSessionRouteChangeReasonKey` → `AVAudioSessionRouteChangeReason`
- `AVAudioSessionRouteChangePreviousRouteKey` →
  `AVAudioSessionRouteDescription` of the route that was active before
  the change.

Source verbatim: archived
[Audio Session Programming Guide — Handling Audio Hardware Route Changes](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioHardwareRouteChanges/HandlingAudioHardwareRouteChanges.html)
(accessed 2026-05-23). Quote: *"Media playback apps should pause
playback if the route change reason is
`AVAudioSessionRouteChangeReasonOldDeviceUnavailable`, but should not
if the reason is `AVAudioSessionRouteChangeReasonOverride`."*

Dspeech is a capture/transcription app, not a playback app, so the
rule is similar but inverted for input:

| Reason (Swift case) | Dspeech response while listening |
|---|---|
| `.newDeviceAvailable` | Recompute route health. If health improved (e.g. user plugged in a USB radio tap mid-session), surface a toast `"Input changed to <portName>"` but keep the same recording continuous; ASR continues. Mark a "route change" marker in the transcript timeline at the timestamp of the change. |
| `.oldDeviceUnavailable` | If the previous route was an external input and `currentRoute.inputs` is now empty or built-in mic, pause ASR, save partials, surface a banner `"Input lost — switched to <portName>"`. User taps "Resume" to continue. We treat this like the playback "pause" guidance but for capture: never silently swap radio input for cabin mic. |
| `.categoryChange` | Recompute route health silently. The category changed, the route may have changed with it. |
| `.override` | Recompute route health silently. Do not pause; the user (or system speakerphone toggle) caused this. |
| `.wakeFromSleep` | Recompute route health silently. |
| `.noSuitableRouteForCategory` | Stop ASR cleanly, surface error banner `"No suitable input"`. |
| `.routeConfigurationChange` | Recompute route health silently. |
| `.unknown` | Log the raw reason value, recompute route health, treat as silent recomputation. |

In all cases, the source audio buffer continues to be captured and
written to the file the engineer's existing pipeline already produces
(so the user can replay and re-run ASR even when route health is bad);
the transcript stream is what gets paused / annotated.

### 2.3 Source audio is the canonical artifact

Confidence-aware transcripts are advisory. The recorded WAV/CAF (or
whatever the existing pipeline writes) plus the route-health timeline
(start, every route change, end) is what we trust for debugging.
This is consistent with the cockpit-voice goal: a flight student who
later disputes a transcript needs the raw audio + the input metadata,
not just the ASR text.

### 2.4 UI copy guardrails

The phrase "input route" or "capture source" is the only correct
label. Never use "radio link", "tower link", "certified", or any
phrase that implies aviation regulatory standing. The app reports
what iOS reports, nothing more.

## 3. Acceptance gates for the engineer

These are the test/quality bars the next slice must meet before
merging. They follow the project's existing pattern (see
`docs/research/2026-05-21-local-atc-speaker-filter.md` phase-1 voice
filter for the analogous test discipline).

### 3.1 Pure route-classification tests

- A `RouteHealthClassifier` type with one public method
  `classify(route: RouteSnapshot, availableInputs: [PortSnapshot]) -> RouteHealth`.
  `RouteSnapshot` and `PortSnapshot` are plain Swift structs the
  classifier owns — they are NOT `AVAudioSessionRouteDescription` or
  `AVAudioSessionPortDescription`. The session adapter (see 3.2) does
  the conversion.
- Unit-tests cover every row of the taxonomy table (§1) plus:
  - empty inputs array → `noInput`
  - one input, `portType == .builtInMic` → `cautionBuiltIn`
  - one input, `portType == .usbAudio` → `suitableExternal`
  - one input, `portType == .bluetoothHFP`, `portName` contains
    aviation-keyword → `suitableExternal`; without keyword still
    `suitableExternal` but flagged for `inputHealthAtStart` so we can
    iterate later (do not over-engineer aviation-keyword logic in this
    slice).
  - `bluetoothA2DP` present and no other input present → expect the
    classifier to receive `availableInputs` reflecting OS fallback
    behavior; expectation: `cautionBuiltIn` if the OS reports
    `builtInMic` as the actual `currentRoute.inputs[0]`, NOT
    `unsuitableOutputOnly`. Document this in a fixture file.
  - unknown raw `portType` string → `unknownExternal`.
- Fixtures live in `tests/Fixtures/AudioRoute/*.json` (or whatever
  fixture pattern phase-1 already uses). Each fixture is a small
  JSON file the test deserializes into `RouteSnapshot`.

### 3.2 Session adapter protocol

- Define `protocol AudioSessionRouting` with:
  - `var currentRouteSnapshot: RouteSnapshot { get }`
  - `var availableInputSnapshots: [PortSnapshot] { get }`
  - `var routeChanges: AsyncStream<RouteChangeEvent> { get }`
  - `func requestRecordPermission() async -> Bool`
  - `func setPreferredInput(uid: String) throws`
- Provide `LiveAudioSessionRouting` (talks to `AVAudioSession`) and
  `FakeAudioSessionRouting` (tests). Production code depends only on
  the protocol.
- The classifier and the route-health view-model take
  `AudioSessionRouting` by initializer injection. No singleton lookup
  inside the domain.
- The live adapter is the only file that imports `AVFAudio`. Any new
  symbol from `AVFoundation` outside that file fails review.

### 3.3 No-go: things this slice MUST NOT do

- No `URLSession`, no `Network.framework`, no cloud calls. This slice
  is offline-only.
- No hardware-purchase prerequisite to land the PR. Reviewer must be
  able to run the unit tests on a Mac with iOS Simulator only.
- No new ASR backend. Use whatever ASR path is already on
  `feat/local-pilot-voice-filter`. The Speech-framework properties
  `taskHint`, `contextualStrings`, `addsPunctuation`,
  `requiresOnDeviceRecognition` are unchanged by this slice; we only
  attach route metadata to the resulting transcript object. Source:
  [SFSpeechRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest)
  (accessed 2026-05-23) and
  [addsPunctuation](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/addspunctuation)
  (accessed 2026-05-23). Both pages are JS-rendered and returned only
  title via WebFetch; the property names and the on-device behavior are
  cited from these canonical URLs but the live page bodies could not
  be quoted verbatim in this session.
- No UI copy that implies a "certified" or "radio-link" guarantee.

### 3.4 Definition of done

1. `RouteHealthClassifier` unit tests pass.
2. `FakeAudioSessionRouting` drives a view-model integration test that
   asserts the chip text/colour for each `RouteHealth` value.
3. The capture screen renders the chip and, on
   `.oldDeviceUnavailable` simulated via the fake, pauses ASR and
   surfaces the banner.
4. Manual smoke on a real iPhone (recorded in the run notes, no
   code-side gate): plug in wired headset → chip flips to green; plug
   in USB-C-to-Lightning + USB audio dongle if available → chip flips
   to green with `usbAudio`; with nothing plugged in → amber with
   `builtInMic`. Andrei runs this once.

## 4. Open questions / uncertainty

These need a real device or a future research pass; do not attempt to
solve them in this slice.

- **BluetoothLE (LE-Audio) reliability for capture.** Apple lists
  `bluetoothLE` in the input-capable port set, but iOS 17+ behavior on
  third-party LE-Audio aviation headsets is not documented enough
  upstream to write a confident classification rule. We classify it as
  `suitableExternal` when present, but the open question is whether
  some LE-Audio devices show up only as output (`headphones` /
  `bluetoothA2DP`) even when they have a mic.
- **Aviation-keyword matching on `portName`.** A Bose A20 over BT will
  show some `portName` like `Bose A20`. We could match a known
  vendor/model list to upgrade `cautionBuiltIn`/`suitableExternal` to
  a "known aviation headset" sub-state. Out of scope for this slice;
  parked as a follow-up.
- **AirPlay as input.** Documented in the port-type list but
  practically rare. Treat as `unknownExternal` for now; revisit if a
  real user hits it.
- **Hardware voice processing.** `AVAudioSessionPortDescription`
  exposes `hasHardwareVoiceCallProcessing`. We could prefer hardware-
  voice-processing-capable inputs for radio audio (which is already
  voice-band). Parked as a follow-up; not needed for the route-health
  chip.
- **Apple doc verbatim quotes.** The current
  developer.apple.com pages for `routeChangeNotification`,
  `AVAudioSession.CategoryOptions/allowBluetoothA2DP`,
  `AVAudioSession`, and the Speech docs are JavaScript-rendered and
  returned only `<title>` to WebFetch in this session
  (2026-05-23). The verbatim API names and behavior in this document
  come from the archived "Audio Session Programming Guide" and
  Technical Q&A QA1799, and from the
  `AVAudioSessionPortDescription` reference page (which did return
  body). On-device verification (e.g. confirming the exact enum
  case name spelling under Swift 5.x — `.newDeviceAvailable` vs
  `.AVAudioSessionRouteChangeReason.newDeviceAvailable`) belongs in
  the engineer slice when compiling against the iOS SDK directly,
  which is the authoritative source.

## 5. Sources

- [AVAudioSessionPortDescription](https://developer.apple.com/documentation/AVFAudio/AVAudioSessionPortDescription)
  (accessed 2026-05-23) — verbatim port-type list (inputs vs output-only).
- [Audio Session Programming Guide — Handling Audio Hardware Route Changes](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioHardwareRouteChanges/HandlingAudioHardwareRouteChanges.html)
  (accessed 2026-05-23) — verbatim route-change-reason guidance and
  Swift example with `AVAudioSessionRouteChangeReasonKey` /
  `AVAudioSessionRouteChangePreviousRouteKey`.
- [Technical Q&A QA1799 — Selecting microphones with AVAudioSession](https://developer.apple.com/library/archive/qa/qa1799/_index.html)
  (accessed 2026-05-23) — verbatim Bluetooth HFP bidirectional-routing
  behavior via `setPreferredInput:error:`.
- [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding_to_audio_route_changes)
  (accessed 2026-05-23) — canonical URL; body JS-rendered, not
  quotable in this session.
- [AVAudioSession.routeChangeNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/1616493-routechangenotification)
  (accessed 2026-05-23) — canonical URL; body JS-rendered, not
  quotable in this session.
- [AVAudioSession.CategoryOptions / allowBluetoothA2DP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp)
  (accessed 2026-05-23) — canonical URL; body JS-rendered, not
  quotable in this session.
- [SFSpeechRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest)
  (accessed 2026-05-23) — canonical URL for the existing ASR request
  properties referenced in §3.3.
- [addsPunctuation](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/addspunctuation)
  (accessed 2026-05-23) — canonical URL referenced in §3.3.

Confidence: medium-high on the route-classification rules
(grounded in verbatim Apple archive content); medium on Bluetooth-LE
behavior (Apple lists it as input-capable but live behavior varies);
on-device verification of the exact Swift symbol spellings is the
final source of truth and belongs in the engineer slice.
