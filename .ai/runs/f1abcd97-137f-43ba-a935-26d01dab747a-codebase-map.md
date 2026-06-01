# Codebase map — pilot-voice filter + callsign-gated ATC display

Run ID: `f1abcd97-137f-43ba-a935-26d01dab747a`
Author: researcher-codebase
Repo: `/home/user/projects/dspeech` @ `main` (clean)
Date: 2026-05-21

## 0. Hard constraints inherited from `CLAUDE.md`

Implementers MUST keep these intact while wiring the voice filter:

- `PrivacyMode.localOnly` (`Dspeech/Core/Settings/PrivacySettings.swift:4-25`) stays the default. Voiceprints, enrolment audio, and the gate decision NEVER leave the device — they live in the same trust domain as the transcript.
- No stale work markers (to-do / fix-me) / unimplemented-panic primitives / "Coming soon" placeholders (`CLAUDE.md:18`). The pilot-filter UI either works or is not shown.
- The `LOCAL` / `CLOUD` badge on the control bar is non-removable (`CLAUDE.md:19`, `ContentView.swift:146`, `ContentView.swift:189-208`). A new "pilot-filter ON / OFF" affordance must be added **next to** it, not replacing it.
- No new outbound network code. SoundAnalysis / on-device ML only.
- Swift 6 strict concurrency is enforced project-wide (`project.pbxproj:99` / `:100` — `SWIFT_STRICT_CONCURRENCY = complete`). Every new type is `Sendable` or annotated `@MainActor` like the existing template.

## 1. What exists today (live path)

| Layer | File | Key lines |
|---|---|---|
| App entry → VM factory | `Dspeech/App/ContentView.swift` | `9-11` `makeDefaultLiveViewModel()` |
| View model (mutates segments, partial, status) | `Dspeech/App/LiveTranscriptionViewModel.swift` | `7-12` state, `43-60` event loop |
| Engine protocol | `Dspeech/Core/ASR/LiveTranscriptionEngine.swift` | `3-24` |
| Engine impl (Apple Speech, on-device) | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` | `83-90` request config; `92-99` audio tap; `125-137` final-segment emission |
| Audio capture contract (unused by live engine; reserved for adapter pattern) | `Dspeech/Core/Audio/AudioCaptureService.swift` | `1-13` |
| Settings template | `Dspeech/Core/Settings/PrivacySettings.swift` | `27-30` storage protocol; `54-75` observable shell |
| Transcript value type | `Dspeech/Core/Models/TranscriptSegment.swift` | `3-39`; `36-38` `requiresVerification` |
| Tests for `LiveTranscriptionViewModel` | `DspeechTests/LiveTranscriptionViewModelTests.swift` | `8-37` `FakeEngine` (template for filter tests) |
| Tests for `PrivacySettings` storage round-trip | `DspeechTests/PrivacySettingsTests.swift` | `7-11` `InMemoryStorage`; `59-72` round-trip |
| Tests for segment domain rules | `DspeechTests/TranscriptSegmentTests.swift` | all 27 lines |

Audio currently runs **once**: `AppleSpeechLiveTranscriptionEngine.startEngineAndTask(...)` installs a single tap on `inputNode` at `AppleSpeechLiveTranscriptionEngine.swift:95-99` that pushes buffers straight into `SFSpeechAudioBufferRecognitionRequest`. There is no fan-out, no buffering layer, no VAD. Today every microphone sample reaches the recognizer — including the pilot's own voice. **This is exactly what we are changing.**

## 2. Existing patterns the implementer MUST preserve

These are the project's convention canon — drift here will be rejected at review.

1. **Protocol-first boundary, struct/class second.** See `LiveTranscriptionEngine` (`LiveTranscriptionEngine.swift:19-24`) + `AppleSpeechLiveTranscriptionEngine` impl, and `PrivacySettingsStorage` (`PrivacySettings.swift:27-30`) + `UserDefaultsPrivacySettingsStorage` impl (`:32-52`). Every new collaborator (voiceprint store, classifier, gate engine, callsign normalizer) follows this shape.
2. **`@MainActor @Observable` for stateful shells, plain `Sendable` value types for data.** Template: `PrivacySettings` (`:54-75`). New `PilotProfileStore` shell uses identical wrapper pattern around a `PilotProfileStorage` protocol.
3. **`Sendable` value types.** `TranscriptSegment` (`TranscriptSegment.swift:3`) and `AudioSampleBuffer` (`AudioCaptureService.swift:3-8`). New `PilotVoiceProfile`, `Voiceprint`, `SpeakerClassification`, `ATCGateDecision` must all be `Equatable, Sendable` value types.
4. **Pure functional core, side effects at boundaries.** `requiresVerification` lives on the value type as a pure derivation (`TranscriptSegment.swift:36-38`). The ATC gate decision engine MUST follow this — pure, fully testable without mocks.
5. **`AsyncStream<Event>` for engine→VM events.** Template: `LiveTranscriptionEngine.events()` (`:21`). Any new pipeline stage that emits over time uses the same shape (or composes on top of the existing engine event stream).
6. **Accessibility identifiers in kebab-case** for any UI Implementers add (`CLAUDE.md:30`). Existing examples: `privacy-badge` (`ContentView.swift:205`), `start-button` (`:108`), `settings-sheet` (`:263`). Add `pilot-filter-badge`, `pilot-enroll-start`, etc.
7. **Swift Testing for domain logic, XCUITest only for UI smoke.** Use `@Test func` style as in `TranscriptSegmentTests.swift`.
8. **Engine cleanup is paired with `cleanup()` + status transition.** Mirror `AppleSpeechLiveTranscriptionEngine.cleanup()` (`:147-157`) when stopping the new capture layer; release the tap, end audio, cancel tasks, deactivate session.

## 3. Files to change / lines to touch

### 3.1 Edits to existing files (small, surgical)

| File | What changes | Why |
|---|---|---|
| `Dspeech/App/ContentView.swift:9-11` `makeDefaultLiveViewModel()` | Inject the new `ATCGate` + `PilotProfileStore` into the engine constructor (or wrap the existing engine with a `FilteredLiveTranscriptionEngine`). Default = unfiltered until the user enrolls. | Single-point composition; keeps DI explicit. |
| `Dspeech/App/ContentView.swift:139-162` `controlBar` | Add a pilot-filter status pill next to `PrivacyBadge` (filter ON when ≥1 enrolled profile + user hasn't disabled). Accessibility identifier `pilot-filter-badge`. | Per `CLAUDE.md:19` + ADR 0002 visibility rule — gating that affects what user sees must be visible. |
| `Dspeech/App/ContentView.swift:210-266` `SettingsView` | New section "Голос пилота / Pilot voice" with: enrolment entry-point (NavigationLink to a `PilotEnrollmentView`), enrolled-profiles list, filter on/off toggle, similarity-threshold expert slider (advanced disclosure). | Mirrors the existing "Приватность" section shape. |
| `Dspeech/App/LiveTranscriptionViewModel.swift:48-58` event handler | When a `.segment` arrives, route it through the callsign relevance scorer; either suppress it (filter mode), or attach a relevance score to the displayed card. **No mutation of `TranscriptSegment`'s existing fields** — add a sibling value type `DisplayedTranscript` if a score must be carried (see §4.5). | Keeps `TranscriptSegment` as the canonical ASR-output value; display gating is a separate concern. |
| `Dspeech/Core/Models/TranscriptSegment.swift:4-8` `Source` enum | Optional: extend with `.liveATC(.atcOnly)` only if implementers find no cleaner home. Default recommendation: leave `TranscriptSegment` alone, add the `DisplayedTranscript` wrapper. | Source is currently a clean three-value enum (`liveATC`, `replay`, `demo`); polluting it risks breaking `TranscriptDemoViewModel` and `TranscriptSegmentTests`. |
| `Dspeech.xcodeproj/project.pbxproj` (all 117 lines, hand-edited) | Add new `PBXBuildFile` + `PBXFileReference` entries for every new `.swift` file; extend `PBXGroup` `Core` (`:62`) with new `VoiceFilter` subgroup; extend Sources phase (`:88`) and Tests Sources phase (`:89`). | `CLAUDE.md:90` — "creating new file entries by appending is fine; renumbering existing ones is not." See §6 for risk details. |

### 3.2 New files

All under `Dspeech/Core/VoiceFilter/`:

```
Dspeech/Core/VoiceFilter/
  PilotVoiceProfile.swift          # domain value type
  Voiceprint.swift                 # opaque embedding wrapper (Sendable)
  SpeakerSimilarityConfig.swift    # threshold + smoothing config
  PilotProfileStorage.swift        # protocol + UserDefaults/keychain impl
  PilotProfileStore.swift          # @MainActor @Observable shell (mirrors PrivacySettings)
  CallsignNormalizer.swift         # pure: phonetic↔ICAO digit/letter normalization
  CallsignRelevanceScorer.swift    # pure: TranscriptSegment + enrolled callsigns → score [0,1]
  ATCGateDecision.swift            # enum + reasons (pure value type)
  ATCGateEngine.swift              # pure functional core: classify+callsign → decision
  SpeakerClassifier.swift          # protocol — speaker similarity classifier
  SoundAnalysisSpeakerClassifier.swift  # impl using Apple SoundAnalysis on iOS 26+
  VoiceprintExtractor.swift        # protocol — PCM segment → Voiceprint
  SoundAnalysisVoiceprintExtractor.swift  # impl (must be verified against Apple docs by researcher-docs)
  SpeechSegmenter.swift            # protocol — PCM stream → speech segments (VAD)
  AudioFanout.swift                # broadcast one PCM tap to N consumers (Sendable channel)
  FilteredLiveTranscriptionEngine.swift  # composes AppleSpeechLiveTranscriptionEngine + gate
  DisplayedTranscript.swift        # display-layer value type carrying TranscriptSegment + ATCGateDecision
```

All under `Dspeech/App/`:

```
Dspeech/App/PilotEnrollmentView.swift          # SwiftUI enrolment flow
Dspeech/App/PilotEnrollmentViewModel.swift     # @MainActor @Observable
```

### 3.3 New test files (under `DspeechTests/`)

```
DspeechTests/CallsignNormalizerTests.swift
DspeechTests/CallsignRelevanceScorerTests.swift
DspeechTests/ATCGateEngineTests.swift
DspeechTests/PilotProfileStorageTests.swift
DspeechTests/PilotProfileStoreTests.swift
DspeechTests/SpeakerSimilarityConfigTests.swift
DspeechTests/FilteredLiveTranscriptionEngineTests.swift
DspeechTests/AudioFanoutTests.swift
```

Optional UI smoke under `DspeechUITests/`:

```
DspeechUITests/PilotFilterBadgeUITests.swift   # asserts pilot-filter-badge accessibility identifier exists
```

## 4. Module-by-module recommended shape

The exact algorithm/internals are out of scope for this map (architect's job). What is fixed here is the **type surface** and the **module boundaries** — implementers code against this.

### 4.1 `PilotVoiceProfile.swift` — domain value type

```swift
import Foundation

struct PilotVoiceProfile: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let displayName: String                 // e.g. "Андрей (left seat)"
    let callsigns: [String]                 // ["N123AB", "SPEEDBIRD 42"]
    let voiceprints: [Voiceprint]           // 1..N enrolment samples
    let createdAt: Date
    let updatedAt: Date
    let language: String                    // BCP-47 of enrolment locale
}
```

Notes:
- `Identifiable` so SwiftUI `ForEach` over the enrolled list works without effort.
- `Codable` enables on-device persistence; **never** transmitted (privacy rule).
- `callsigns` are arbitrary user-entered strings here; canonicalization lives in `CallsignNormalizer`.

### 4.2 `Voiceprint.swift` — opaque embedding

```swift
struct Voiceprint: Equatable, Sendable, Codable {
    let modelTag: String        // identifies the embedding model+version (e.g. "soundanalysis-speakerid-v1")
    let dimension: Int
    let values: [Float]         // L2-normalized; size == dimension
    let capturedAt: Date
    let durationSeconds: Double
}
```

Strong opinion: do **not** expose the float vector to consumers — only the classifier reads it. Voiceprint comparison is one function:
```swift
extension Voiceprint {
    static func cosineSimilarity(_ a: Voiceprint, _ b: Voiceprint) -> Float?  // nil on model-tag mismatch
}
```

### 4.3 `SpeakerSimilarityConfig.swift`

```swift
struct SpeakerSimilarityConfig: Equatable, Sendable, Codable {
    var pilotThreshold: Float         // e.g. 0.78
    var hysteresisDelta: Float        // e.g. 0.04 — to avoid flapping
    var minSpeechSeconds: Double      // ignore <250ms blips
    var smoothingWindow: Int          // last N classifications combined

    static let `default` = SpeakerSimilarityConfig(
        pilotThreshold: 0.78,
        hysteresisDelta: 0.04,
        minSpeechSeconds: 0.25,
        smoothingWindow: 3
    )
}
```

Why a config type, not constants: lets the expert-slider in Settings drive it, lets tests inject extreme values, lets future eval-harness sweep thresholds.

### 4.4 `PilotProfileStorage.swift` + `PilotProfileStore.swift`

Mirror **exactly** the `PrivacySettings` template (`PrivacySettings.swift:27-75`).

```swift
protocol PilotProfileStorage: Sendable {
    func loadProfiles() -> [PilotVoiceProfile]
    func saveProfiles(_ profiles: [PilotVoiceProfile])
    func loadConfig() -> SpeakerSimilarityConfig
    func saveConfig(_ config: SpeakerSimilarityConfig)
    func loadFilterEnabled() -> Bool
    func saveFilterEnabled(_ enabled: Bool)
}

@MainActor
@Observable
final class PilotProfileStore {
    private(set) var profiles: [PilotVoiceProfile]
    var config: SpeakerSimilarityConfig { didSet { /* persist */ } }
    var filterEnabled: Bool { didSet { /* persist */ } }
    init(storage: PilotProfileStorage = UserDefaultsPilotProfileStorage()) { ... }
    func add(_ profile: PilotVoiceProfile) { ... }
    func remove(id: UUID) { ... }
}
```

Persistence detail: voiceprint vectors can be largish (~1 KB each). `UserDefaults` is acceptable for MVP — but isolate behind the protocol so a future move to file-based JSON / Keychain is a one-file change. Use the same `*.v1` key namespacing as `PrivacySettings.privacyModeKey` (`:33`).

### 4.5 `DisplayedTranscript.swift` — UI-side wrapper

The decision NOT to mutate `TranscriptSegment` matters:

```swift
struct DisplayedTranscript: Identifiable, Equatable, Sendable {
    let id: UUID                        // == segment.id
    let segment: TranscriptSegment
    let gate: ATCGateDecision
    var callsignRelevance: Double       // [0..1]; 0 = irrelevant to enrolled callsigns
}
```

`LiveTranscriptionViewModel.segments` should become `[DisplayedTranscript]` (or a sibling collection `displayed`), and `ContentView.transcriptArea` iterates over those. The existing `TranscriptSegmentCard` API takes a `TranscriptSegment` so changes there are minimal — pass `displayed.segment` plus, optionally, a relevance badge.

### 4.6 `CallsignNormalizer.swift` — pure

Functions only:
```swift
enum CallsignNormalizer {
    static func canonicalize(_ raw: String) -> String          // "Speedbird forty two" → "SPEEDBIRD 42"
    static func extractCandidates(_ text: String) -> [String]  // scans ATC transcript for callsign-shaped tokens
    static func phoneticToDigits(_ text: String) -> String     // "one two three" → "123"
}
```

Pure, no I/O, no actor. Trivially testable.

### 4.7 `CallsignRelevanceScorer.swift` — pure

```swift
struct CallsignRelevanceScorer: Sendable {
    let enrolledCallsigns: [String]    // already canonicalized

    func score(segmentText: String) -> Double  // [0..1]
}
```

Algorithm choices (substring, edit distance, ICAO digit-to-word fuzz) are the implementer's call. The boundary is fixed: text in, score out, no state.

### 4.8 `ATCGateDecision.swift` + `ATCGateEngine.swift` — pure functional core

```swift
enum ATCGateDecision: Equatable, Sendable {
    case dropPilotVoice(similarity: Float, threshold: Float)
    case forwardToASR(speakerConfidence: Float, reason: Reason)

    enum Reason: String, Sendable {
        case noEnrolledProfile          // filter off
        case belowPilotThreshold
        case relevantToEnrolledCallsign
        case filterDisabledByUser
    }
}
```

```swift
struct ATCGateEngine: Sendable {
    let config: SpeakerSimilarityConfig
    let profiles: [PilotVoiceProfile]
    let filterEnabled: Bool

    /// Pure: speech segment → drop or forward decision.
    /// Returns the decision and (if forwarded) the raw PCM/identifier to push to ASR.
    func decide(
        speechClip: SpeechClipFingerprint,   // contains best-matching pilot similarity already computed by classifier
        recentDecisions: [ATCGateDecision]   // for hysteresis/smoothing
    ) -> ATCGateDecision
}
```

This is the heart of the discipline: **no I/O, no actor, fully testable with table-driven Swift Testing.**

### 4.9 `SpeakerClassifier.swift` + `SoundAnalysisSpeakerClassifier.swift`

```swift
protocol SpeakerClassifier: Sendable {
    func classify(_ clip: PCMSpeechSegment, against profiles: [PilotVoiceProfile]) async -> SpeakerClassification
}

struct SpeakerClassification: Equatable, Sendable {
    let bestProfileId: UUID?
    let similarity: Float           // 0..1
    let modelTag: String
}
```

`SoundAnalysisSpeakerClassifier` is the only non-pure module that crosses the Apple boundary. It SHOULD use `SoundAnalysis` framework APIs available on iOS 26+ for speaker embeddings — **but the exact API surface must be verified by `researcher-docs` against Apple's iOS 26 SoundAnalysis docs before the implementer commits.** This map does not pin a specific Apple class.

### 4.10 `SpeechSegmenter.swift` + `AudioFanout.swift`

The current engine taps `inputNode` once (`AppleSpeechLiveTranscriptionEngine.swift:95-99`). We need:

```swift
protocol SpeechSegmenter: Sendable {
    /// Consumes raw PCM, emits speech-only clips with start/end timestamps.
    func segments(from pcm: AsyncStream<PCMFrame>) -> AsyncStream<PCMSpeechSegment>
}

actor AudioFanout {
    /// Broadcasts one PCM tap to N async consumers.
    func subscribe() -> AsyncStream<PCMFrame>
}
```

`AudioFanout` is the **single piece of state** that solves the "capture raw PCM once" requirement. One physical `installTap` → fanout → (classifier consumer, ASR consumer).

### 4.11 `FilteredLiveTranscriptionEngine.swift`

This is the wiring class — implements `LiveTranscriptionEngine` (the same protocol `AppleSpeechLiveTranscriptionEngine` implements), so `LiveTranscriptionViewModel` does not change its dependency type at all.

```swift
@MainActor
final class FilteredLiveTranscriptionEngine: LiveTranscriptionEngine {
    init(
        underlying: AppleSpeechLiveTranscriptionEngine,
        fanout: AudioFanout,
        segmenter: any SpeechSegmenter,
        classifier: any SpeakerClassifier,
        gate: ATCGateEngine,
        callsignScorer: CallsignRelevanceScorer,
        store: PilotProfileStore
    )
    // events() / start() / stop() forward to `underlying`, but raw audio is routed via `fanout`
    // and ASR-bound buffers are only appended when `gate.decide(...) == .forwardToASR(...)`.
}
```

Replacing the line `LiveTranscriptionViewModel(engine: AppleSpeechLiveTranscriptionEngine())` (`ContentView.swift:10`) with the composed engine is the only change in `ContentView.makeDefaultLiveViewModel()`.

## 5. End-to-end ASR/audio integration shape

The mandated flow:

```
inputNode tap (once, in AppleSpeechLiveTranscriptionEngine)
   └─→ AudioFanout
        ├─→ SpeechSegmenter ──→ SpeakerClassifier ──→ ATCGateEngine.decide(...)
        │                                                │
        │                                                ├─ .dropPilotVoice  → discarded, never enters SFSpeechAudioBufferRecognitionRequest
        │                                                │
        │                                                └─ .forwardToASR    → frames replayed (or live-tapped via shared buffer) into SFSpeechAudioBufferRecognitionRequest.append(_:)
        │
        └─→ (debug only, behind compile-time flag) on-device waveform meter
```

`LiveTranscriptionViewModel` consumes the same `AsyncStream<LiveTranscriptionEvent>` it always has. On `.segment`, it ALSO runs `CallsignRelevanceScorer.score(segmentText:)` and wraps the result into a `DisplayedTranscript`. Suppression mode (`filterEnabled == true` AND relevance < user threshold) drops the card; soft mode (default) just dims it. **Settings owns which mode is active.**

The pilot's own ATC readback is by construction excluded **before** ASR runs — saving battery, reducing false transcripts, and matching the privacy/UX intent of the product. Callsign relevance is the second filter layer (handles overheard chatter on the same frequency that isn't addressed to this pilot).

## 6. Tests to write (before/with implementation)

Use Swift Testing (`@Test`). Mirror the in-memory storage pattern from `PrivacySettingsTests.swift:7-11`.

| Test file | Property under test | Hooks into |
|---|---|---|
| `CallsignNormalizerTests.swift` | "Speedbird forty two" → "SPEEDBIRD 42"; "one two three alpha bravo" → "123AB"; idempotency; whitespace; case | pure function |
| `CallsignRelevanceScorerTests.swift` | exact match = 1.0; phonetic match = high; unrelated callsign = low; empty enrolled list = 0; multiple enrolled, only one referenced | pure |
| `ATCGateEngineTests.swift` | filter disabled → always forward with reason `filterDisabledByUser`; no profiles → forward with reason `noEnrolledProfile`; sim > threshold → drop; sim < threshold − hysteresis → forward; smoothing window prevents single-frame flap | pure, table-driven |
| `PilotProfileStorageTests.swift` | `UserDefaults` round-trip for profiles, config, filter flag; per `PrivacySettingsTests.userDefaultsRoundTrip:59-72` template | uses unique suite name UUID, defer cleanup |
| `PilotProfileStoreTests.swift` | default `filterEnabled == false`; adding profile flips badge eligibility; remove by id; config setter persists | uses `InMemoryStorage` test double |
| `SpeakerSimilarityConfigTests.swift` | `Codable` round-trip; default values; threshold ordering | pure |
| `FilteredLiveTranscriptionEngineTests.swift` | Stub `SpeakerClassifier` + stub `AppleSpeechLiveTranscriptionEngine` via the protocol — assert: (a) when classifier says "pilot", no `.segment` reaches `events()`; (b) when classifier says "other", `.segment` does reach `events()`; (c) `stop()` cleanly tears both layers down | uses `FakeEngine` pattern from `LiveTranscriptionViewModelTests.swift:8-37` |
| `AudioFanoutTests.swift` | 1 producer → 2 subscribers: both receive every frame in order; cancellation of one subscriber does not affect the other; back-pressure does not OOM | property-style table |
| Property-based test (optional, `swift-testing` parameterized) on `ATCGateEngine.decide` | invariants: (1) `filterEnabled == false` → always forward; (2) decision changes within hysteresis band require sustained signal | parameterized `@Test(arguments:)` |

UI smoke (`DspeechUITests/PilotFilterBadgeUITests.swift`): launch app, assert `pilot-filter-badge` exists and reads "OFF" by default (no profiles enrolled). Mirrors current UI test discipline.

## 7. Xcode project + SPM risks (read before touching `project.pbxproj`)

The `.xcodeproj` is **hand-edited, hand-numbered**, and small (`Dspeech.xcodeproj/project.pbxproj:1-117`, 117 lines total). Critical observations:

1. **`A0000000000000000000XXXX` IDs are dense and sequential.** Last allocated IDs at time of writing: `0077` (build file refs). The `CLAUDE.md:90` rule says appending new IDs is fine, renumbering existing ones is not.
2. **Allocation plan for new files (suggested, no clashes with existing 0000–0077):**

   New `PBXFileReference` IDs `0080`–`0099` for the 14+ new VoiceFilter Swift files, `0100`–`0109` for the 2 new App Swift files, `0110`–`0119` for the test files.
   Matching `PBXBuildFile` IDs `0120`–`0149`.
   New `PBXGroup` ID `0080`-prefix collides — use `0079` for `VoiceFilter` group, `0078` for any new App-level grouping if needed.

   Implementer should pick the exact ranges; the point is: stay strictly above `0077`, never reuse.
3. **New group placement.** Add `VoiceFilter` group as a child of `Core` (group ref `A00000000000000000000006` at `:62`) right after `Settings`. Add `PilotEnrollmentView.swift` + `PilotEnrollmentViewModel.swift` to the existing `App` group (`A00000000000000000000005` at `:61`).
4. **Sources phase membership.**
   - All new app/core Swift files MUST be added to the Dspeech target's Sources phase (`A00000000000000000000018` at `:88`).
   - All new test files MUST be added to the DspeechTests Sources phase (`A00000000000000000000021` at `:89`).
   - UI test files (if any) go into `A00000000000000000000024` (`:90`).
5. **No SPM dependency required for this slice.** Pilot voice filtering uses Apple's `SoundAnalysis` (system framework) and `AVFoundation` (already linked) and `Accelerate` (for cosine similarity — system framework). **Do NOT add `Package.swift` or an SPM remote dependency** — the project currently has zero SPM packages (`project.pbxproj` contains no `XCRemoteSwiftPackageReference` section), and adding one would force a much bigger pbxproj rewrite. If the implementer is tempted to pull WhisperKit / a third-party speaker-ID model, they MUST first land a separate ADR (see ADR 0001 precedent).
6. **Frameworks Build Phase is empty** for all three targets (`project.pbxproj:51-55`). `SoundAnalysis` and `Accelerate` import via `import` statement work without explicit linking (Swift auto-link), but if the implementer hits a linker error, the fix is to add a `PBXBuildFile` entry for `SoundAnalysis.framework` and reference it from the Frameworks phase — **not** to add SPM.
7. **`SWIFT_STRICT_CONCURRENCY = complete`** is set on both Debug and Release (`:99-100`). Every new actor/class/struct MUST be `Sendable`-clean. `AudioFanout` SHOULD be an `actor` (not `class`); `ATCGateEngine` SHOULD be a `struct` with no reference-type fields.
8. **iOS deployment target is 26.0** (`:99 IPHONEOS_DEPLOYMENT_TARGET = 26.0`, also `:103-106`). No `#available(iOS 17.0, *)` gates are needed for `SoundAnalysis`-2026 APIs — they're guaranteed available. Implementer can delete defensive availability checks.
9. **Info.plist additions.** The current `NSMicrophoneUsageDescription` (`:101`) is sufficient — we're not asking for a new permission. **No new Info.plist key** is required for SoundAnalysis-based speaker classification (it operates on the existing microphone grant).

## 8. Files NOT to touch in this slice

- `Dspeech/Core/ASR/SpeechRecognitionService.swift` (`:1-6`) — older `AsyncThrowingStream`-based protocol, currently unused by the live path. Leave for the future replay/file ingestion adapter. Don't pull it into the filter wiring.
- `Dspeech/App/TranscriptDemoViewModel.swift` — `.demo` segments are exempt by `CLAUDE.md:18`. Filter MUST NOT run on demo segments; the engine path is different.
- `Dspeech/Core/Audio/AudioCaptureService.swift:10-12` `AudioCaptureService` protocol — keep as-is (it's a future adapter contract). `AudioFanout` is a sibling, not a replacement.
- `docs/adr/0002-privacy-local-only-default.md` — the pilot-voice work is consistent with ADR 0002 (no off-device transmission); only write a new ADR if implementers introduce a third `PrivacyMode` case or a new local model artifact that needs cataloguing.

## 9. Order of implementation (for the implementers, not this map's deliverable)

This is for the planner who picks this up next; included for completeness so testers know what to write first.

1. **Red tests** for `CallsignNormalizer`, `CallsignRelevanceScorer`, `SpeakerSimilarityConfig`, `ATCGateEngine` — all pure, all writeable before any I/O code.
2. **Green** the pure-core implementations.
3. **Red tests** for `PilotProfileStorage` + `PilotProfileStore` using `InMemoryStorage` pattern from `PrivacySettingsTests.swift:7-11`.
4. **Green** the storage shell.
5. **`AudioFanout`** with deterministic actor tests.
6. **`SpeakerClassifier` protocol + stub impl** (real `SoundAnalysis` impl deferred until `researcher-docs` confirms API).
7. **`FilteredLiveTranscriptionEngine`** wired with stubs; test it with `FakeEngine`+stub classifier; ensure `LiveTranscriptionViewModel` is unchanged.
8. **`SoundAnalysisSpeakerClassifier` + `SoundAnalysisVoiceprintExtractor`** real implementations.
9. **UI**: SettingsView section, enrolment flow, pilot-filter badge in control bar.
10. **`xcodebuild build test`** green on mac24 per `CLAUDE.md:36-41`. ADR addendum if any new persisted artifact is introduced.

## 10. Open questions to flag back to CEO / docs-researcher (NOT to silently decide)

1. Which Apple iOS 26 SoundAnalysis class is the canonical speaker-embedding entry point? `researcher-docs` must verify against current Apple docs before any of `SoundAnalysisSpeakerClassifier.swift` ships.
2. Acceptable enrolment duration: 3 × 5 s or 1 × 15 s? Affects UX flow more than code shape, but the storage layer should be agnostic — store N voiceprints per profile.
3. Should `PilotProfileStorage` use `UserDefaults` (simple, fits the existing `PrivacySettings` pattern, ~10 KB OK) or `FileManager` JSON in Application Support (cleaner for >10 enrolled samples)? **Recommend `UserDefaults` for MVP**, protocol allows later swap with zero call-site changes.
4. Should there be a separate ADR for "pilot voiceprint stored on-device" to formally extend ADR 0002's scope, or does the existing local-only guarantee cover it? **Recommend new ADR 0007** so the privacy story is explicit when marketing talks about voice profiles.
5. Hard-suppress vs soft-dim default for relevance? Recommend **soft-dim** + **explicit Settings toggle** to hard-suppress; users in noisy frequency conditions will want the harder filter, but default-suppression risks losing a critical call.

---

End of map. No source files were modified in producing this document.
