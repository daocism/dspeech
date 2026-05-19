# Swift-6 actor-isolation & `Sendable` audit — MVP-slice seams

Read-only inventory of every `@MainActor`, `nonisolated`, `Sendable`,
`@unchecked Sendable`, and `actor` annotation across the W2/W3/W4/W5 surfaces,
plus the expected calling actor for each public method per
`docs/architecture-mvp-slice-2026-05-19.md` "Test seams" /
"Threading (Swift 6.0 now; Swift 6.2 approachable-concurrency aware)" (lines
145-157). Branch: `burn/21-threading-model-audit`. No remediation in this
dossier — findings only.

Scope (per dispatch frontmatter): `Dspeech/Core/Audio/*.swift`,
`Dspeech/Core/Translation/*.swift`, `Dspeech/Core/FirstRun/*.swift`,
`Dspeech/Core/ASR/*.swift`, `Dspeech/Core/Settings/*.swift`,
`Dspeech/Core/Models/*.swift`, `Dspeech/App/LiveTranscriptionViewModel.swift`,
`Dspeech/App/TranscriptDemoViewModel.swift`. SwiftUI views and `DspeechApp.swift`
are deliberately out of scope.

Project posture: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
nonisolated-by-default (cited in
`docs/architecture-mvp-slice-2026-05-19.md:147-148`).

## 1. Type inventory

Column legend — *Isolation*: how the type is annotated, not how it is used.
*Crosses async boundary*: at least one declared member is `async` or yields onto
an `AsyncStream` / `AsyncThrowingStream`.

| Type | Defining file:line | Kind | Isolation | Stored mutable state | Crosses an `async` boundary |
| --- | --- | --- | --- | --- | --- |
| `TranscriptSegment` | `Dspeech/Core/Models/TranscriptSegment.swift:3` | struct | `Sendable` (all `let`) | no | no |
| `TranscriptSegment.Source` | `Dspeech/Core/Models/TranscriptSegment.swift:4` | enum | `Sendable` | no | no |
| `PrivacyMode` | `Dspeech/Core/Settings/PrivacySettings.swift:4` | enum | `Sendable, Codable` | no | no |
| `PrivacySettingsStorage` | `Dspeech/Core/Settings/PrivacySettings.swift:27` | protocol | `Sendable` | n/a | no (both methods sync) |
| `UserDefaultsPrivacySettingsStorage` | `Dspeech/Core/Settings/PrivacySettings.swift:32` | struct | `@unchecked Sendable` | no (`let defaults`) | no |
| `PrivacySettings` | `Dspeech/Core/Settings/PrivacySettings.swift:54-56` | final class | `@MainActor @Observable` | yes (`var mode`) | no (sync storage) |
| `AudioSampleBuffer` | `Dspeech/Core/Audio/AudioCaptureService.swift:3` | struct | `Sendable` (all `let`) | no | no |
| `AudioCaptureService` | `Dspeech/Core/Audio/AudioCaptureService.swift:10` | protocol | `Sendable` | n/a | yes (returns `AsyncThrowingStream`) |
| `AudioRoute` | `Dspeech/Core/Audio/AudioRoute.swift:19` | enum (assoc.) | `Sendable` | no | no |
| `AudioRouteChangeObserver` | `Dspeech/Core/Audio/AudioRouteChangeObserver.swift:23` | struct | implicit `Sendable` (annotated; all `let`, closure is `@Sendable`) | no | yes (returns `AsyncStream`) |
| `AudioInputKind` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:9` | enum | `Sendable, Codable` | no | no |
| `AudioInputDescriptor` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:32` | struct | `Sendable, Codable` (all `let`) | no | no |
| `AudioInputLevel` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:52` | struct | `Sendable` (all `let`) | no | no |
| `AudioRouteChangeReason` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:76` | enum | `Sendable` | no | no |
| `AudioRouteChange` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:86` | struct | `Sendable` (all `let`) | no | no |
| `AudioInputServiceError` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:101` | enum (Error) | `Sendable` | no | no |
| `AudioInputService` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:133` | protocol | `Sendable` | n/a | yes (`levels()`, `routeChanges()`) |
| `AudioPortSnapshot` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:174` | struct | `Sendable` (all `let`) | no | no |
| `AudioRouteChangeEvent` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:195` | struct | `Sendable` (all `let`) | no | no |
| `AudioInputSessionPort` | `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:243` | protocol | `Sendable` | n/a | yes (`routeChangeEvents()`) |
| `AppleAudioInputService` | `Dspeech/Core/Audio/AudioInputService.swift:83` | final class | `@unchecked Sendable` | no (all `let`) | yes (returns streams) |
| `AVFoundationAudioInputSessionPort` | `Dspeech/Core/Audio/AudioInputService.swift:309` | final class | `@unchecked Sendable` | no (`let session`) | yes (`routeChangeEvents`) |
| `MeteringSession` | `Dspeech/Core/Audio/AudioInputService.swift:398` | private final class | `@unchecked Sendable` | yes (`let engine = AVAudioEngine()`; engine's *internal* state mutates on `start`/`stop`) | invoked from stream builder + `onTermination` |
| `TranslationLanguageStatus` | `Dspeech/Core/Translation/TranslationServiceProtocol.swift:9` | enum | `Sendable` | no | no |
| `TranslationServiceError` | `Dspeech/Core/Translation/TranslationServiceProtocol.swift:28` | enum (Error) | `Sendable` | no | no |
| `TranslationService` | `Dspeech/Core/Translation/TranslationServiceProtocol.swift:79` | protocol | `Sendable` | n/a | yes (both methods `async`) |
| `TranslationLanguagePackPreparer` | `Dspeech/Core/Translation/TranslationServiceProtocol.swift:117` | protocol | `Sendable` | n/a | yes (`async throws`) |
| `AppleTranslationService` | `Dspeech/Core/Translation/TranslationService.swift:37` | struct | implicit `Sendable` (stateless) | no | yes |
| `LocalTranslationService` | `Dspeech/Core/Translation/TranslationService.swift:137` | struct | implicit `Sendable` (one `Sendable` `let`) | no | yes |
| `TranslationPackSystemDownloadPort` | `Dspeech/Core/Translation/TranslationLanguagePackManager.swift:28` | protocol | `Sendable` | n/a | yes (`async throws`) |
| `AppleTranslationLanguagePackManager` | `Dspeech/Core/Translation/TranslationLanguagePackManager.swift:61` | struct | implicit `Sendable` | no | yes |
| `TranslationLanguagePackManager` | `Dspeech/Core/Translation/TranslationLanguagePackManager.swift:102` | struct | implicit `Sendable` | no | yes |
| `LiveTranscriptionStatus` | `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:3` | enum (assoc.) | `Sendable` | no | no |
| `LiveTranscriptionEvent` | `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:12` | enum (assoc.) | `Sendable` | no | no |
| `LiveTranscriptionEngine` | `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:18-19` | protocol (`AnyObject`) | `@MainActor` | n/a | yes (`start() async`, `events()`) |
| `AppleSpeechLiveTranscriptionEngine` | `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:5-6` | final class | `@MainActor` | yes (`status`, `recognizer`, `request`, `task`, `continuation`) | yes |
| `SpeechRecognitionService` | `Dspeech/Core/ASR/SpeechRecognitionService.swift:3` | protocol | `Sendable` | n/a | yes (returns `AsyncThrowingStream`) |
| `FirstRunCard` | `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:7` | enum | `Sendable, CaseIterable` | no | no |
| `FirstRunState` | `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:22` | enum (assoc.) | `Sendable` | no | no |
| `FirstRunCoordinatorError` | `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:34` | enum (Error) | `Sendable` | no | no |
| `FirstRunStateStore` | `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:43` | protocol | `Sendable` | n/a | no (both sync) |
| `FirstRunCoordinator` | `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:64` | protocol | `Sendable` | n/a | no (all three methods sync) |
| `UserDefaultsFirstRunStateStore` | `Dspeech/Core/FirstRun/FirstRunCoordinator.swift:15` | struct | `@unchecked Sendable` | no (`let defaults`) | no |
| `DefaultFirstRunCoordinator` | `Dspeech/Core/FirstRun/FirstRunCoordinator.swift:52` | final class | `@unchecked Sendable` | yes (`var cardIndex`, guarded by `NSLock`) | no |
| `LiveTranscriptionViewModel` | `Dspeech/App/LiveTranscriptionViewModel.swift:4-6` | final class | `@MainActor @Observable` | yes (`segments`, `partialText`, `status`, `eventTask`) | yes (consumes `engine.events()`) |
| `TranscriptDemoViewModel` | `Dspeech/App/TranscriptDemoViewModel.swift:4-6` | final class | `@MainActor @Observable` | yes (`var segments`) | no |

Notes:

- The task frontmatter lists protocol `FirstRunCoordinatorProtocol`; the actual
  protocol type is `FirstRunCoordinator`
  (`Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:64`). The file is
  named `…Protocol.swift` per repo convention but the protocol is not — every
  reference below uses the source-of-truth name.
- `AudioRouteChangeObserver` is declared `struct … : Sendable`
  (`Dspeech/Core/Audio/AudioRouteChangeObserver.swift:23`). Listed as "implicit
  Sendable (annotated)" because the conformance is explicit but compiler-checked
  rather than `@unchecked` (no AVFoundation type held — note the source comment
  at lines 20-22).

## 2. Public-method isolation contract per protocol

Per `docs/architecture-mvp-slice-2026-05-19.md:147-157` ("All three service
protocols are `: Sendable` with `async` methods (or `Sendable`-element
streams), so isolation is explicit and stays correct if the project later
adopts Swift 6.2 `defaultIsolation(MainActor.self)`"), the three frozen
non-ASR protocols are deliberately *not* main-actor-isolated; the ASR protocol
predates the slice and is `@MainActor` by design (PLAN: "F1 ASR — unchanged"
at `docs/architecture-mvp-slice-2026-05-19.md:111`).

### `AudioInputService` (`Dspeech/Core/Audio/AudioInputServiceProtocol.swift:133`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `availableInputs()` | `throws(AudioInputServiceError) -> [AudioInputDescriptor]` (line 138) | caller-chosen (typed-throws sync) |
| `currentInput()` | `-> AudioInputDescriptor?` (line 142) | caller-chosen (sync, pure read) |
| `select(_:)` | `throws(AudioInputServiceError)` (line 149) | caller-chosen (typed-throws sync) |
| `levels()` | `-> AsyncThrowingStream<AudioInputLevel, Error>` (line 157) | caller-chosen; consumer hops to its own actor |
| `routeChanges()` | `-> AsyncStream<AudioRouteChange>` (line 161) | caller-chosen; consumer hops to its own actor |

Drift: no method is `async`. The DocC at lines 130-132 states "`AVAudioSession`
work is off the main actor; the route-change notification is posted on a
secondary thread (Apple DocC), so the conforming type hops to the picker view
model's actor". The synchronous `availableInputs()` / `select()` therefore
*block whichever actor calls them*. If a `@MainActor` view model calls them
directly, MainActor is blocked while `AVAudioSession.setCategory` /
`setActive` / `availableInputs` runs — see finding F-3 in §5.

### `AudioInputSessionPort` (`Dspeech/Core/Audio/AudioInputServiceProtocol.swift:243`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `configureForMeasurement()` | `throws(AudioInputServiceError)` (line 249) | caller-chosen (sync) |
| `activate()` | `throws(AudioInputServiceError)` (line 254) | caller-chosen (sync) |
| `availablePorts()` | `-> [AudioPortSnapshot]` (line 259) | caller-chosen (sync) |
| `currentInputPort()` | `-> AudioPortSnapshot?` (line 263) | caller-chosen (sync) |
| `setPreferredInput(portUID:)` | `throws(AudioInputServiceError)` (line 273) | caller-chosen (sync) |
| `routeChangeEvents()` | `-> AsyncStream<AudioRouteChangeEvent>` (line 278) | caller-chosen; consumer hops |

DocC at lines 240-242 affirms `Sendable` posture under nonisolated-default and
future `defaultIsolation(MainActor.self)`. Same sync-blocks-caller observation
as `AudioInputService`.

### `TranslationService` (`Dspeech/Core/Translation/TranslationServiceProtocol.swift:79`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `availability(translatingFrom:into:)` | `async -> TranslationLanguageStatus` (line 84) | caller-chosen (async; Apple's `LanguageAvailability` work runs off-caller) |
| `translate(_:from:into:)` | `async throws(TranslationServiceError) -> String` (line 94) | caller-chosen (async, typed-throws) |

Matches the doc's "isolation is explicit and stays correct" posture; no drift.

### `TranslationLanguagePackPreparer` (`Dspeech/Core/Translation/TranslationServiceProtocol.swift:117`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `prepareLanguages(from:into:)` | `async throws(TranslationServiceError)` (line 125) | caller-chosen; the OS-gated download UI is owned by the SwiftUI integrator seam (per DocC lines 102-116) |

### `TranslationPackSystemDownloadPort` (`Dspeech/Core/Translation/TranslationLanguagePackManager.swift:28`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `requestSystemDownload(from:into:)` | `async throws(TranslationServiceError)` (line 38) | caller-chosen; conforming type lives at the SwiftUI seam (W5) |

### `SpeechRecognitionService` (`Dspeech/Core/ASR/SpeechRecognitionService.swift:3`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `transcribe(_:)` | `-> AsyncThrowingStream<TranscriptSegment, Error>` (line 4) | caller-chosen (sync factory; the stream itself crosses the async boundary) |

No conformer in the audited surface — this protocol is unused by the live ASR
path (`AppleSpeechLiveTranscriptionEngine` implements `LiveTranscriptionEngine`,
not `SpeechRecognitionService`). Latent shape, kept for the replay path
(`TranscriptSegment.Source.replay`,
`Dspeech/Core/Models/TranscriptSegment.swift:6`).

### `LiveTranscriptionEngine` (`Dspeech/Core/ASR/LiveTranscriptionEngine.swift:18-19`)

Protocol is `@MainActor` and refines `AnyObject`.

| Method / property | Signature | Expected caller |
| --- | --- | --- |
| `status` | `{ get }` (line 20) | `MainActor` |
| `events()` | `-> AsyncStream<LiveTranscriptionEvent>` (line 21) | `MainActor` factory; consumed via `for await` on any actor |
| `start()` | `async` (line 22) | `MainActor` |
| `stop()` | `()` sync (line 23) | `MainActor` |

Mismatch (informational, not drift): `events()` is declared `@MainActor` (it
inherits protocol isolation) but the AsyncStream it returns can be drained from
any actor. The consumer `LiveTranscriptionViewModel.startObservingEvents()` at
`Dspeech/App/LiveTranscriptionViewModel.swift:43-60` wraps the drain in a
`Task { @MainActor [weak self] }` — that is correct under Swift 6.0 but only
because the engine's `continuation?.yield` calls happen on MainActor
(`AppleSpeechLiveTranscriptionEngine.emit(_:)` at line 159-161 runs in the
`@MainActor` class scope), so element delivery is already on MainActor; the
Task @MainActor annotation in the VM is therefore redundant for safety though
useful for clarity.

### `FirstRunCoordinator` (`Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:64`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `currentState()` | `-> FirstRunState` (line 67) | caller-chosen (sync) |
| `advance()` | `throws(FirstRunCoordinatorError) -> FirstRunState` (line 74) | caller-chosen (typed-throws sync) |
| `skip()` | `throws(FirstRunCoordinatorError)` (line 79) | caller-chosen (typed-throws sync) |

DocC at lines 59-63: "`Sendable` so it can be injected into a `@MainActor
@Observable` onboarding view model the way `PrivacySettings` consumes
`PrivacySettingsStorage`; the concrete type (W4a) may itself be `@MainActor`.
Method isolation is explicit, so this is correct under Swift 6.0
nonisolated-default and a future Swift 6.2 main-actor-default migration alike."
The concrete `DefaultFirstRunCoordinator` is *not* `@MainActor`; it is
`@unchecked Sendable` with an `NSLock` (see §3). Calling these synchronous
methods from MainActor will acquire `NSLock` on MainActor — bounded and brief,
but blocking.

### `FirstRunStateStore` (`Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:43`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `hasCompletedFirstRun()` | `-> Bool` (line 46) | caller-chosen (sync) |
| `markFirstRunCompleted()` | `throws(FirstRunCoordinatorError)` (line 52) | caller-chosen (typed-throws sync) |

### `PrivacySettingsStorage` (`Dspeech/Core/Settings/PrivacySettings.swift:27`)

| Method | Signature | Expected caller |
| --- | --- | --- |
| `loadPrivacyMode()` | `-> PrivacyMode` (line 28) | caller-chosen (sync) |
| `savePrivacyMode(_:)` | `()` (line 29) | caller-chosen (sync) |

## 3. `@unchecked Sendable` register

Six concrete conformances. Each row quotes the justifying comment verbatim and
judges whether the conformance is structurally safe.

| Type | Location | Justification (verbatim from source) | Justified now? | Comparison to the reference exemplar (`UserDefaultsPrivacySettingsStorage`) |
| --- | --- | --- | --- | --- |
| `UserDefaultsPrivacySettingsStorage` | `Dspeech/Core/Settings/PrivacySettings.swift:32` | *(no inline justification on this line — type is the project-wide template)* | Yes. All members are `let`; `UserDefaults` is documented thread-safe by Apple. Used by `PrivacySettings` from MainActor through a `Sendable` storage handle. | This *is* the exemplar. |
| `UserDefaultsFirstRunStateStore` | `Dspeech/Core/FirstRun/FirstRunCoordinator.swift:15` | "Mirrors the `UserDefaultsPrivacySettingsStorage` template … a nonisolated `@unchecked Sendable` value type so it satisfies the `Sendable`, synchronous ``FirstRunStateStore`` requirements without main-actor isolation." (lines 5-8) | Yes. Same shape as exemplar: only stored member is `let defaults: UserDefaults`. | Identical pattern. |
| `DefaultFirstRunCoordinator` | `Dspeech/Core/FirstRun/FirstRunCoordinator.swift:52` | "`@unchecked Sendable` with an `NSLock` guarding the only mutable state (the card cursor) — the concurrency-primitive exception to immutability, the same shape as the `PrivacySettings` storage template but with a class because progression must survive across `advance()` calls within an onboarding session." (lines 41-46) | Yes — the lock covers every read and every write of `cardIndex` (`currentState()` lines 62-68, `advance()` lines 70-85). `store.markFirstRunCompleted()` is called *outside* the lock (line 83) which is correct because the store is itself `Sendable` and the lock guards only `cardIndex`. | Diverges from the exemplar because the type is a *class*. The divergence is justified inline and bounded by the `NSLock`. |
| `AppleAudioInputService` | `Dspeech/Core/Audio/AudioInputService.swift:83` | "`@unchecked Sendable` mirrors the `UserDefaultsPrivacySettingsStorage` precedent: the injected port is `Sendable`; the debounce closure is `@Sendable`; no mutable state is held." (lines 80-82) | Yes. All three stored members are `let` (lines 95-97). The class could in principle be a struct or carry implicit `Sendable` — `@unchecked` is conservative but not unsound. | Same posture as exemplar, with a class wrapper. |
| `AVFoundationAudioInputSessionPort` | `Dspeech/Core/Audio/AudioInputService.swift:309` | "`@unchecked Sendable`: holds no mutable state — every entry point reads the process-wide `AVAudioSession.sharedInstance()` shared with the ASR engine." (lines 307-308) | Yes structurally (only stored member is `let session`), but the conformance is structurally unverifiable because `AVAudioSession` is imported `@preconcurrency` at `Dspeech/Core/Audio/AudioInputService.swift:1`. The compiler cannot prove `AVAudioSession`'s thread-safety; Apple's documentation does (DocC `documentation/avfaudio/avaudiosession` is the process-wide thread-safe singleton). | Same posture as exemplar; the only delta is that the held value is an Apple singleton imported `@preconcurrency`. |
| `MeteringSession` | `Dspeech/Core/Audio/AudioInputService.swift:398` | "`@unchecked Sendable`: `start` runs once on the stream-builder, `stop` once on stream termination; the realtime tap block touches only the `@Sendable` callback and its local buffer, never `engine`. Same `@preconcurrency AVFoundation` capture pattern as `AppleSpeechLiveTranscriptionEngine.swift`, which builds green under Swift 6 strict-concurrency `complete`." (lines 393-397) | **Partially.** The "start runs once / stop runs once" invariant is enforced *by usage* in `AppleAudioInputService.levels()` at `Dspeech/Core/Audio/AudioInputService.swift:131-144` — one `MeteringSession()` per stream, `start` inside the builder, `stop` inside `onTermination`. There is no compile-time barrier preventing a second call sequence. The two callers are also unsynchronized relative to each other (stream-builder context vs `onTermination` context). See finding F-1 in §5. | Diverges from the exemplar: holds a value with internal mutation (`AVAudioEngine`), unlike `let defaults`. The invariant is a usage contract rather than a structural property. |

## 4. `AsyncStream` / `AsyncThrowingStream` inventory

| Declaration | File:line | Producer | Consumer (per audited code) | Cancellation | Element `Sendable`? |
| --- | --- | --- | --- | --- | --- |
| `AudioCaptureService.samples()` | `Dspeech/Core/Audio/AudioCaptureService.swift:11` | no in-scope conformer | n/a in scope | n/a | yes — `AudioSampleBuffer` |
| `SpeechRecognitionService.transcribe(_:)` | `Dspeech/Core/ASR/SpeechRecognitionService.swift:4` | no in-scope conformer | n/a in scope | n/a | yes — `TranscriptSegment` |
| `LiveTranscriptionEngine.events()` | `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:21` (protocol); impl at `AppleSpeechLiveTranscriptionEngine.swift:22-32` | MainActor: `emit(_:)` at lines 159-161 (called from `didSet` of `status` line 7-9, and from `Task { @MainActor }` blocks at lines 96-99 / 104-122) | `LiveTranscriptionViewModel.startObservingEvents()` at `Dspeech/App/LiveTranscriptionViewModel.swift:43-60`, drained on MainActor | `continuation.onTermination = { … Task { @MainActor … stop() } }` at lines 26-30 — bounces back to MainActor, calls `stop()`. Producer side has no `Task.isCancelled` check (events are pushed from `didSet` / Task closures, not a pump loop) | yes — `LiveTranscriptionEvent` |
| `AppleAudioInputService.levels()` | `Dspeech/Core/Audio/AudioInputService.swift:131-144` | `MeteringSession`'s tap block (audio thread; calls `onLevel(level)` which calls `continuation.yield(level)` from line 137) | per dispatch — picker VM (W3a, not yet audited beyond `Dspeech/App/LiveTranscriptionViewModel.swift` which is not the picker VM) | `continuation.onTermination = { _ in metering.stop() }` (line 142). Producer has no in-loop cancel check — tap is removed by `stop()` | yes — `AudioInputLevel` |
| `AppleAudioInputService.routeChanges()` | `Dspeech/Core/Audio/AudioInputService.swift:146-152` | `debounced(_:interval:sleep:transform:)` pump Task at lines 242-260 | picker VM | `continuation.onTermination = { _ in pump.cancel() }` at line 262; the pump loop's `for await element in upstream` exits on upstream finish; the in-flight delayed Task is awaited at line 259; the survivor checks `Task.isCancelled` at line 254 before yielding | yes — `AudioRouteChange` |
| `AudioRouteChangeObserver.routes()` | `Dspeech/Core/Audio/AudioRouteChangeObserver.swift:38-46` | shared `AppleAudioInputService.debounced(…)` pump (same as above) | route-display surface (W5) | inherited from `debounced` (same as above) | yes — `AudioRoute` |
| `AVFoundationAudioInputSessionPort.routeChangeEvents()` | `Dspeech/Core/Audio/AudioInputService.swift:353-371` | `Task { … for await notification in NotificationCenter.default.notifications(named:) … continuation.yield(AudioRouteChangeEvent(…)) }`. `NotificationCenter.default.notifications(named:)` is `@preconcurrency` (imported via `@preconcurrency import AVFoundation` for the userInfo key, and Foundation for the method). Notifications are posted on a secondary thread (DocC `documentation/avfaudio/avaudiosession/routechangenotification`, cited at lines 50-52). | `AppleAudioInputService.routeChanges()` / `AudioRouteChangeObserver.routes()` via `debounced` | `continuation.onTermination = { _ in task.cancel() }` at line 369. The notification `for await` loop terminates when the task is cancelled. | yes — `AudioRouteChangeEvent` |

Cross-cutting observation: every stream in the audited surface installs an
`onTermination` handler. The only stream whose *producer* lacks an in-loop
`Task.isCancelled` check is the engine's `events()` — by design, because it is
push-driven (`didSet` + ad-hoc `Task { @MainActor }`) rather than a pump loop.

## 5. Drift & risk findings (no fixes here)

### F-1 — `MeteringSession.@unchecked Sendable` rests on a usage invariant, not a structural one — MEDIUM

- **File:line:** `Dspeech/Core/Audio/AudioInputService.swift:393-423`
- **Evidence:** the type holds `private let engine = AVAudioEngine()`
  (line 399) whose state is mutated by `start(_:)` (installs tap, runs
  `engine.start()`) and `stop()` (calls `engine.stop()` and `removeTap`). The
  inline justification (lines 393-397) states "`start` runs once on the
  stream-builder, `stop` once on stream termination" — this is enforced by
  `AppleAudioInputService.levels()` at lines 131-144, **not** by the type.
- **Risk under Swift 6.0 strict-concurrency:** the compiler accepts the
  `@unchecked` claim. A future call site that runs `start` twice, or runs
  `start`/`stop` from racing actors, would create an unsynchronized mutation
  of `engine` without any compiler warning. The "AVAudioEngine + tap" block
  itself runs on a realtime audio thread Apple controls — its
  `@Sendable` callback parameter only reaches `onLevel` (line 405-409), which
  is the contained safe path.
- **Why not CRITICAL:** the single caller today (`levels()`) does enforce the
  invariant; the failure mode is latent, not active.

### F-2 — Two-phase audio-engine teardown in `MeteringSession.stop` could race with a still-running tap block — MEDIUM

- **File:line:** `Dspeech/Core/Audio/AudioInputService.swift:419-422`
- **Evidence:**

  ```swift
  func stop() {
      if engine.isRunning { engine.stop() }
      engine.inputNode.removeTap(onBus: 0)
  }
  ```

  Between `engine.stop()` and `removeTap` an in-flight tap-block invocation
  could fire `onLevel(level)` → `continuation.yield(level)` on a continuation
  whose consumer has already terminated (the `onTermination` invocation that
  triggered this `stop()`). `continuation.yield` after termination is a no-op
  per `AsyncStream` semantics, so this is benign in observable behavior —
  *but* the tap block holds a `@Sendable (AudioInputLevel) -> Void` reference
  whose lifetime is "until removeTap returns". On `@preconcurrency
  AVFoundation`, this lifetime is not statically verifiable.
- **Risk:** Tap-block callback ordering relative to `stop()` is documented by
  Apple as "the block is delivered on an internal queue"
  (DocC reference at lines 64-65 in the same file). Strict-concurrency under
  Swift 6.0 cannot prove the callback won't outlive `removeTap`. Practical
  failure mode is a no-op `yield`; no crash, no race on user state.

### F-3 — `AudioInputService` synchronous methods will block whichever actor calls them; the architecture doc claims AVAudioSession work runs "off the main actor" — MEDIUM

- **File:line:** `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:138-149`
  vs DocC at lines 130-132 ("`AVAudioSession` work is off the main actor")
  and `docs/architecture-mvp-slice-2026-05-19.md:152` ("Adapters do
  AVAudioSession/Translation work off the main actor").
- **Evidence:** `availableInputs()`, `currentInput()`, `select(_:)` are
  declared synchronous. The conformer
  `AppleAudioInputService.availableInputs()` (`Dspeech/Core/Audio/AudioInputService.swift:109-116`)
  calls `port.configureForMeasurement()` which lands at
  `AVFoundationAudioInputSessionPort.configureForMeasurement()`
  (lines 316-322) and invokes `session.setCategory(.record, mode:
  .measurement, options: [.duckOthers])` synchronously. If a `@MainActor`
  view model calls `availableInputs()`, this `setCategory` runs on MainActor.
- **Risk under Swift 6.0:** correct (no isolation violation); the doc's
  "off the main actor" expectation is *not enforced by the protocol shape*.
  A future migration to `defaultIsolation(MainActor.self)` would make the
  protocol implicitly `@MainActor`, at which point the synchronous body
  pinning the AVAudioSession work to MainActor would become a documented
  drift between architecture intent and signature. Today the protocol is
  `: Sendable` with sync methods (not `async`), so the caller chooses where
  the work runs, but nothing forces it off MainActor.

### F-4 — `LiveTranscriptionEngine.events()` is single-subscriber by construction; second call replaces the continuation silently — MEDIUM

- **File:line:** `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:22-32`
- **Evidence:**

  ```swift
  func events() -> AsyncStream<LiveTranscriptionEvent> {
      AsyncStream<LiveTranscriptionEvent> { continuation in
          self.continuation = continuation
          continuation.yield(.status(self.status))
          continuation.onTermination = { [weak self] _ in
              Task { @MainActor [weak self] in
                  self?.stop()
              }
          }
      }
  }
  ```

  Calling `events()` twice replaces `self.continuation`. The original
  continuation is now orphaned: nothing calls `continuation.finish()` on it,
  no `onTermination` fires for it from a teardown action of the new caller,
  and the producer (`emit(_:)` line 159-161) only ever writes to the *current*
  `self.continuation?`. The orphaned continuation's consumer Task awaits
  forever (until garbage collected on engine deinit).
- **Risk under Swift 6.0:** not an isolation violation. It is a single-writer
  / single-reader contract that the protocol does not advertise. The current
  consumer `LiveTranscriptionViewModel.startObservingEvents()` guards against
  this with `if eventTask == nil { startObservingEvents() }` at
  `Dspeech/App/LiveTranscriptionViewModel.swift:28-30` — i.e. a usage
  invariant in the VM. Re-injecting a different engine instance into a fresh
  VM is the only safe pattern.

### F-5 — `AppleSpeechLiveTranscriptionEngine` tap block creates one detached `Task { @MainActor }` per audio buffer — LOW

- **File:line:** `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:95-99`
- **Evidence:**

  ```swift
  inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
      Task { @MainActor [weak self] in
          self?.request?.append(buffer)
      }
  }
  ```

  At 16 kHz mono with a 1024-frame buffer, this is ~16 Tasks/second — modest
  in steady state but each spawn allocates a Task and a continuation hop.
  `request.append(buffer)` then runs on MainActor.
- **Risk under Swift 6.0:** no isolation violation (`SFSpeechAudioBufferRecognitionRequest.append`
  on MainActor is acceptable per `@preconcurrency Speech` import). Latent
  performance/latency risk under sustained high-rate input: every audio
  buffer enters the MainActor queue. Not a correctness problem; out of scope
  per dispatch (F1 ASR unchanged).

### F-6 — `@preconcurrency import AVFoundation`/`Speech` suppresses Sendable warnings on Apple types — LOW

- **File:line:** `Dspeech/Core/Audio/AudioInputService.swift:1`,
  `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:1-2`
- **Evidence:** both files use `@preconcurrency import AVFoundation` (and
  `Speech` in the ASR engine). Per SE-0337 ("Incremental migration to
  concurrency checking") the `@preconcurrency` modifier disables strict
  `Sendable` enforcement for imported symbols. `AVAudioSession`,
  `AVAudioEngine`, `SFSpeechRecognizer`, `SFSpeechRecognitionTask`,
  `AVAudioPCMBuffer` would otherwise emit warnings when crossed into
  `Sendable` contexts.
- **Risk:** the type system cannot verify thread-safety of these Apple types
  inside the audited code; the audit relies on DocC narrative
  (`Dspeech/Core/Audio/AudioInputService.swift:38-72` for AVFoundation;
  Speech engine reliance is implicit). This is the canonical Swift-6
  trade-off and is acknowledged in the source comments
  (`Dspeech/Core/Audio/AudioInputService.swift:394-397`).

### F-7 — `FirstRunCoordinator` synchronous I/O on MainActor is documented as acceptable but uses `NSLock` blocking — LOW

- **File:line:** `Dspeech/Core/FirstRun/FirstRunCoordinator.swift:62-68, 70-85`
- **Evidence:** `DefaultFirstRunCoordinator.currentState()` calls
  `store.hasCompletedFirstRun()` (UserDefaults read) and then
  `lock.lock()` / `lock.unlock()` around a read of `cardIndex`. From a
  `@MainActor` onboarding VM, the lock is acquired on MainActor.
- **Risk:** lock acquisition is uncontended in practice (the VM is the only
  caller); the read is a single integer fetch. Bounded by the absence of
  contention. Documented in the source at lines 41-46 as "the
  concurrency-primitive exception to immutability". No drift.

### F-8 — `SpeechRecognitionService` protocol has no conformer in the audited surface — LOW

- **File:line:** `Dspeech/Core/ASR/SpeechRecognitionService.swift:3-5`
- **Evidence:** the live ASR path implements `LiveTranscriptionEngine`
  (`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:6`), not
  `SpeechRecognitionService`. The latter's `transcribe(_:)` signature is
  `Sendable`-clean and unused.
- **Risk:** none under Swift 6.0; flagged only because the audit task asked
  to enumerate every protocol's expected calling actor. The protocol is
  latent; isolation contract is moot until a conformer exists.

### F-9 — `AppleSpeechLiveTranscriptionEngine.continuation` is `var` on a `@MainActor` class but is captured into the AsyncStream builder closure — LOW

- **File:line:** `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:16`
  (declaration), `:24` (assignment inside the builder closure).
- **Evidence:** the builder closure passed to `AsyncStream { continuation in
  self.continuation = continuation … }` (lines 23-31) inherits the
  enclosing `@MainActor` isolation, so the `self.continuation =` write is
  on MainActor. The closure itself is invoked synchronously by the
  `AsyncStream` initializer, so MainActor isolation holds.
- **Risk:** no Swift 6.0 isolation violation. The mutable `var` could be
  `private(set)` to harden the contract; the absence is not unsafe, only
  loose.

### F-10 — `AudioRouteChangeObserver` plain `Sendable` (not `@unchecked`) while debounce captures a closure — informational

- **File:line:** `Dspeech/Core/Audio/AudioRouteChangeObserver.swift:23-36`
- **Evidence:** declared `struct AudioRouteChangeObserver: Sendable` with
  three `let` members; the closure `sleep` is `@Sendable`. The compiler
  accepts the conformance because every stored member is `Sendable`.
- **Risk:** none. Recorded for completeness — this is the *correct* shape
  the other six `@unchecked Sendable` types could converge to if they shed
  their AVFoundation holds.

Severity totals: 0 CRITICAL, 0 HIGH, 4 MEDIUM (F-1, F-2, F-3, F-4), 5 LOW
(F-5, F-6, F-7, F-8, F-9), 1 informational (F-10) — 10 findings total.

## 6. References

- `docs/architecture-mvp-slice-2026-05-19.md` lines 145-157 ("Threading"),
  159-177 ("Test seams"), 179-208 ("Audio adapter DI seam").
- `docs/PLAN-2026-05-19.md` (DAG and W7 gate, referenced at architecture
  doc line 9).
- `CLAUDE.md` (project root) — Swift 6 strict-concurrency requirement and the
  fail-fast / typed-throws posture.
- `Dspeech/Core/Settings/PrivacySettings.swift:32` — the project-wide
  `@unchecked Sendable` reference exemplar.
- Apple DocC paths inlined in the audited source — verbatim, no inventions:
  `documentation/avfaudio/avaudiosession/routechangenotification`
  (`Dspeech/Core/Audio/AudioInputService.swift:55-57`);
  `documentation/translation/languageavailability/status(from:to:)`
  (`Dspeech/Core/Translation/TranslationService.swift:14-16`);
  `documentation/translation/translationsession/init(installedsource:target:)`
  (`Dspeech/Core/Translation/TranslationService.swift:17-20`).
- Swift Evolution: SE-0337 "Incremental migration to concurrency checking"
  (referenced via `@preconcurrency import` in
  `Dspeech/Core/Audio/AudioInputService.swift:1` and
  `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:1-2`). SE numbers
  for `defaultIsolation(MainActor.self)` and typed-throws-across-async are
  UNKNOWN — verify before adoption (the architecture doc cites them
  narratively at lines 150-151 / 240-242 without an SE-NNNN reference).
