# Error taxonomy — MVP services (Audio / Translation / FirstRun / ASR / Settings)

Read-only inventory of every `throws` site, custom `Error`/`LocalizedError` type, and
`Result` failure mode across the MVP Core services, plus the one App boundary that catches
each typed family. Snapshot date: 2026-05-20. HEAD at write time: `6b113f6`. Branch:
`burn/17-error-taxonomy` (the burn-lane worktree already named the branch with its issue
number prefix; the task frontmatter's `burn/error-taxonomy` is the unprefixed form).

No `Result<_, _>` type appears anywhere in the in-scope code. The codebase uses Swift's
typed-throws (`throws(SomeError)`) and `AsyncThrowingStream<_, Error>` as its only failure
channels. No `LocalizedError` conformance exists on any in-scope `Error` type — user-facing
copy is produced by view-layer `describe(_:)` switches, not by `errorDescription`.

Verification scope (each file in scope was fully read; counts below):

| File | LoC | Throws sites | Catch sites |
| --- | --- | --- | --- |
| `Dspeech/Core/Audio/AudioCaptureService.swift` | 12 | 0 (protocol-only) | 0 |
| `Dspeech/Core/Audio/AudioInputServiceProtocol.swift` | 279 | 5 (protocol decls) | 0 |
| `Dspeech/Core/Audio/AudioInputService.swift` | 423 | 8 | 5 (4 typed + 1 untyped in stream) |
| `Dspeech/Core/Audio/AudioRoute.swift` | 47 | 0 | 0 |
| `Dspeech/Core/Audio/AudioRouteChangeObserver.swift` | 47 | 0 | 0 |
| `Dspeech/Core/Translation/TranslationServiceProtocol.swift` | 129 | 2 (protocol decls) | 0 |
| `Dspeech/Core/Translation/TranslationService.swift` | 167 | 4 | 1 (typed multi-catch, 8 arms) |
| `Dspeech/Core/Translation/TranslationLanguagePackManager.swift` | 115 | 3 (1 protocol + 2 impl) | 0 |
| `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift` | 80 | 3 (protocol decls) | 0 |
| `Dspeech/Core/FirstRun/FirstRunCoordinator.swift` | 91 | 3 | 0 |
| `Dspeech/Core/ASR/SpeechRecognitionService.swift` | 5 | 0 (protocol-only) | 0 |
| `Dspeech/Core/ASR/LiveTranscriptionEngine.swift` | 24 | 0 (status-driven) | 0 |
| `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift` | 182 | 5 (untyped) | 1 untyped + 1 `try?` |
| `Dspeech/Core/Settings/PrivacySettings.swift` | 75 | 0 | 0 |


## 1. AudioInputServiceError

**Declared:** `Dspeech/Core/Audio/AudioInputServiceProtocol.swift:101-116`
- Conforms to `Error, Equatable, Sendable`.
- Does **not** conform to `LocalizedError` — no `errorDescription`.
- Cases (with associated values):
  - `.audioSessionUnavailable(String)` — protocol DocC line 102.
  - `.noInputsAvailable` — protocol DocC line 105.
  - `.inputNotSelectable(AudioInputDescriptor)` — protocol DocC line 108. Only typed error in this taxonomy that carries a full domain value (not just a string).
  - `.activationFailed(String)` — protocol DocC line 111.
  - `.meteringUnavailable(String)` — protocol DocC line 114.

**Protocol surface (typed-throws):**
- `AudioInputService.availableInputs()` — `AudioInputServiceProtocol.swift:138`.
- `AudioInputService.select(_:)` — `AudioInputServiceProtocol.swift:149`.
- `AudioInputSessionPort.configureForMeasurement()` — `AudioInputServiceProtocol.swift:249`.
- `AudioInputSessionPort.activate()` — `AudioInputServiceProtocol.swift:254`.
- `AudioInputSessionPort.setPreferredInput(portUID:)` — `AudioInputServiceProtocol.swift:273`.
- `AudioInputService.levels()` — `AudioInputServiceProtocol.swift:157` — returns
  `AsyncThrowingStream<AudioInputLevel, Error>` (failure type erased to `Error`, see §1.3).

**Throw sites (Core):**
- `AudioInputService.swift:113` — `throw .noInputsAvailable` inside
  `AppleAudioInputService.availableInputs()`.
- `AudioInputService.swift:126` — `throw .inputNotSelectable(input)` inside
  `AppleAudioInputService.select(_:)` (orchestrator pre-check before delegating to the port).
- `AudioInputService.swift:320` — `throw .audioSessionUnavailable(error.localizedDescription)`
  in `AVFoundationAudioInputSessionPort.configureForMeasurement()` (maps untyped AVFoundation
  throw from `setCategory(_:mode:options:)`).
- `AudioInputService.swift:328` — `throw .activationFailed(error.localizedDescription)` in
  `AVFoundationAudioInputSessionPort.activate()` (maps `setActive(_:options:)` failure).
- `AudioInputService.swift:344` — `throw .activationFailed("preferred input \(portUID) no longer available")`
  in `AVFoundationAudioInputSessionPort.setPreferredInput(portUID:)` (port-level disappearance
  after orchestrator's pre-check, e.g. cable yanked between check and call).
- `AudioInputService.swift:349` — `throw .activationFailed(error.localizedDescription)` —
  AVFoundation `setPreferredInput(_:)` rejection.
- `AudioInputService.swift:415` — `throw .meteringUnavailable(error.localizedDescription)`
  in `MeteringSession.start(_:)` (maps `AVAudioEngine.start()` failure).

**Internal Core catch sites (re-typing untyped AVFoundation throws):**
- `AudioInputService.swift:317-321` → mapped to `.audioSessionUnavailable`.
- `AudioInputService.swift:325-329` → mapped to `.activationFailed`.
- `AudioInputService.swift:346-350` → mapped to `.activationFailed`.
- `AudioInputService.swift:411-416` → mapped to `.meteringUnavailable`.
- `AudioInputService.swift:134-141` — `levels()` `do…catch`: the typed error is **re-thrown
  untyped** via `continuation.finish(throwing: error)` because the stream's failure type is
  `Error` (Apple framework constraint — `AsyncThrowingStream` has no typed-failure variant in
  iOS 26). See §1.3.

**Single subsystem boundary (App-side):**
- `Dspeech/App/SettingsSheet+Sections.swift:95-104` — `AudioSourceSettingsSection.reload()`,
  `do { try service.availableInputs() } catch { ... }` — Swift narrows the catch to
  `AudioInputServiceError` because the protocol declaration is `throws(AudioInputServiceError)`.
- `Dspeech/App/SettingsSheet+Sections.swift:106-114` — `select(_:)`.
- `Dspeech/App/SettingsSheet+Sections.swift:116-125` — `observeLevels()` (untyped catch, see §1.3).
- `Dspeech/App/SettingsSheet+Sections.swift:145-158` — `describe(_:)` exhaustive switch
  producing the Russian user-facing copy. This is the lone consumer that maps every case.

**Cross-service crossings:** none. The error stays inside the Audio subsystem.

### 1.3 Untyped-`Error` leak through `levels()` stream

`AsyncThrowingStream<AudioInputLevel, Error>` returned by `AudioInputService.levels()` erases
the failure type. `AppleAudioInputService.levels()` re-throws the typed error untyped
(`AudioInputService.swift:139`), and the boundary at `SettingsSheet+Sections.swift:116-125`
catches it as `Error` and unconditionally produces `"Метр уровня недоступен."`. Result: of
the five `AudioInputServiceError` cases, only `.meteringUnavailable` can in practice reach
this stream — but the boundary cannot **prove** that; if a future caller routes a different
case here, the user-facing copy will silently miscategorize. Findings-only: do not switch on
the typed case here today.


## 2. TranslationServiceError

**Declared:** `Dspeech/Core/Translation/TranslationServiceProtocol.swift:28-58`
- Conforms to `Error, Equatable, Sendable`.
- Does **not** conform to `LocalizedError`.
- Cases:
  - `.emptyInput` — protocol DocC line 29.
  - `.sourceLanguageUnsupported(Locale.Language)` — line 32.
  - `.targetLanguageUnsupported(Locale.Language)` — line 36.
  - `.languagePairingUnsupported(source: Locale.Language, target: Locale.Language)` — line 40.
  - `.languagePackNotInstalled(source: Locale.Language, target: Locale.Language)` — line 44.
  - `.sessionCancelled` — line 50.
  - `.engineFailure(String)` — line 53.

**Protocol surface (typed-throws):**
- `TranslationService.translate(_:from:into:)` — `TranslationServiceProtocol.swift:94-98`.
- `TranslationLanguagePackPreparer.prepareLanguages(from:into:)` —
  `TranslationServiceProtocol.swift:125-128`.
- `TranslationPackSystemDownloadPort.requestSystemDownload(from:into:)` —
  `TranslationLanguagePackManager.swift:38-41`.

**Throw sites (Core):**
- `TranslationService.swift:85` — `throw .emptyInput` in `AppleTranslationService.translate(_:from:into:)` (pre-check on trimmed input).
- `TranslationService.swift:91` — `throw .languagePackNotInstalled(source:target:)` (availability precheck `.downloadable` branch).
- `TranslationService.swift:93` — `throw .languagePairingUnsupported(source:target:)` (availability precheck `.unsupported` branch).
- `TranslationService.swift:101` — `throw .emptyInput` (mapped from `Translation.TranslationError.nothingToTranslate`).
- `TranslationService.swift:103` — `throw .languagePackNotInstalled` (mapped from `TranslationError.notInstalled`).
- `TranslationService.swift:105` — `throw .sourceLanguageUnsupported(source)` (mapped from `TranslationError.unsupportedSourceLanguage`).
- `TranslationService.swift:107` — `throw .targetLanguageUnsupported(target)` (mapped from `TranslationError.unsupportedTargetLanguage`).
- `TranslationService.swift:109` — `throw .languagePairingUnsupported` (mapped from `TranslationError.unsupportedLanguagePairing`).
- `TranslationService.swift:111` — `throw .sessionCancelled` (mapped from `TranslationError.alreadyCancelled`).
- `TranslationService.swift:113` — `throw .sessionCancelled` (mapped from `CancellationError`).
- `TranslationService.swift:115` — `throw .engineFailure(String(describing: error))` (last-resort untyped framework throw).
- `TranslationService.swift:164` — `throw .emptyInput` in `LocalTranslationService.translate(_:from:into:)` (decorator pre-check; the inner `AppleTranslationService` repeats the trim pre-check, so a non-empty `text` whose trimmed form is empty is caught twice — both produce `.emptyInput`).
- `TranslationLanguagePackManager.swift:79` — `throw .languagePairingUnsupported` in `AppleTranslationLanguagePackManager.prepareLanguages(from:into:)` (status `.unsupported` arm).
- `TranslationLanguagePackManager.swift:81` — `throw .languagePairingUnsupported` (`@unknown default` arm — fail-closed for future `LanguageAvailability.Status` cases).

**Re-throw sites (forwarders):**
- `TranslationService.swift:165` — `LocalTranslationService.translate` `try await backend.translate(...)`.
- `TranslationLanguagePackManager.swift:77` — `AppleTranslationLanguagePackManager.prepareLanguages` `try await systemDownloadPort.requestSystemDownload(...)`.
- `TranslationLanguagePackManager.swift:113` — `TranslationLanguagePackManager.prepareLanguages` `try await backend.prepareLanguages(...)`.

**Internal Core catch site (re-typing Apple `TranslationError`):**
- `TranslationService.swift:96-117` — eight-arm typed-catch over `Translation.TranslationError`
  + `CancellationError` + untyped catch-all. This is the single Translation→Core re-typing
  boundary. Every Apple `TranslationError` static case is enumerated; `unknown default` is
  the catch-all `.engineFailure`.

**Single subsystem boundary (App-side):**
- `Dspeech/App/SettingsSheet+Sections.swift:256-269` — `TranslationSettingsSection.downloadPack()`
  is the lone consumer of `TranslationLanguagePackPreparer.prepareLanguages(_:_:)`.
- `Dspeech/App/SettingsSheet+Sections.swift:271-288` — `describe(_:)` exhaustive switch over
  all seven `TranslationServiceError` cases producing Russian user-facing copy.
- **No app-side consumer of `TranslationService.translate(_:from:into:)`** yet — the
  per-segment translation flow has not been wired into the live transcript view (the
  `ContentView` only reads `segment.translatedText`, which the demo VM populates statically).
  When that wiring lands, it will need its own boundary or share this one.

**Secondary SwiftUI-seam re-throw / mapping (still inside App):**
- `Dspeech/App/SettingsSheet.swift:130-150` — `TranslationPackDownloadCoordinator.requestDownload(from:into:)` typed-throws `TranslationServiceError`:
  - `:135` `throw .engineFailure("pack download already in progress")` (re-entrancy guard).
  - `:144` re-throws caught `TranslationServiceError` unchanged.
  - `:146` maps `CancellationError` → `.sessionCancelled`.
  - `:148` last-resort untyped → `.engineFailure(String(describing: error))`.
- `Dspeech/App/SettingsSheet.swift:77-92` — the `.translationTask` closure catches Apple's
  `TranslationError` cases (`unsupportedLanguagePairing`, `alreadyCancelled`, `CancellationError`,
  untyped) and resolves a `TranslationPackDownloadOutcome` (`SettingsSheet.swift:185-190`),
  which `resolve(_:)` (`:157-177`) then maps onto `TranslationServiceError`. This is a
  parallel mapping table to `TranslationService.swift:96-117` but covers only the subset
  reachable via `prepareTranslation()`.

**Cross-service crossings:** none — Translation errors never reach Audio or FirstRun. The
two App-side mapping tables (`TranslationService.swift:96-117` and `SettingsSheet.swift:77-92`)
duplicate the Apple-`TranslationError`→`TranslationServiceError` mapping; see §5 gap analysis.


## 3. FirstRunCoordinatorError

**Declared:** `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift:34-36`
- Conforms to `Error, Equatable, Sendable`.
- Does **not** conform to `LocalizedError`.
- Cases:
  - `.persistenceUnavailable(String)` — the only case.

**Protocol surface (typed-throws):**
- `FirstRunStateStore.markFirstRunCompleted()` — `FirstRunCoordinatorProtocol.swift:52`.
- `FirstRunCoordinator.advance()` — `FirstRunCoordinatorProtocol.swift:74`.
- `FirstRunCoordinator.skip()` — `FirstRunCoordinatorProtocol.swift:79`.

**Throw sites (Core):**
- `FirstRunCoordinator.swift:31` — `throw .persistenceUnavailable("UserDefaults did not retain \(Self.completedDefaultsKey)")` in `UserDefaultsFirstRunStateStore.markFirstRunCompleted()` — sanity readback after the `set(true, forKey:)` call.

**Re-throw sites:**
- `FirstRunCoordinator.swift:83` — `DefaultFirstRunCoordinator.advance()` `try store.markFirstRunCompleted()` on the last-card path.
- `FirstRunCoordinator.swift:89` — `DefaultFirstRunCoordinator.skip()` `try store.markFirstRunCompleted()`.

**Single subsystem boundary (App-side):**
- `Dspeech/App/FirstRunView.swift:100-107` — `FirstRunViewModel.advance()`.
- `Dspeech/App/FirstRunView.swift:109-117` — `FirstRunViewModel.skip()`.
- `Dspeech/App/FirstRunView.swift:127-133` — `FirstRunViewModel.finish()` (post-permission second `advance()`).
- `Dspeech/App/FirstRunView.swift:139-144` — `describe(_:)` (one-arm switch since the enum has one case).

**Cross-service crossings:** none.


## 4. ASR errors — `LiveTranscriptionStatus.failed(String)` (no `Error` type)

`AppleSpeechLiveTranscriptionEngine` does **not** declare an `Error` type. Failures are
surfaced as a status-machine string case, **not** thrown:

**Declared:** `Dspeech/Core/ASR/LiveTranscriptionEngine.swift:3-10`
- `enum LiveTranscriptionStatus: Equatable, Sendable { ... case failed(String) }`.
- Status is observed via `AsyncStream<LiveTranscriptionEvent>` (non-throwing).

**Internal throw sites (untyped, Core-private):**
- `AppleSpeechLiveTranscriptionEngine.swift:76` — `private func beginAudioSession() throws`
  (untyped) — `try session.setCategory(...)` line 78, `try session.setActive(...)` line 79.
- `AppleSpeechLiveTranscriptionEngine.swift:82` — `private func startEngineAndTask(recognizer:) throws`
  (untyped) — `try audioEngine.start()` line 102.

**Internal catch site (re-typing into status string):**
- `AppleSpeechLiveTranscriptionEngine.swift:58-66` — single `do { try beginAudioSession(); try startEngineAndTask(...); status = .listening } catch { status = .failed("start-failed: \(error.localizedDescription)"); cleanup() }`.
  Every AVFoundation/Speech failure on the start path collapses into one opaque
  `"start-failed: <raw localizedDescription>"` string. The two permission paths
  (`speech-permission-denied` line 41, `microphone-permission-denied` line 46) and the
  no-recognizer path (`recognizer-unavailable` line 53) are unreachable via `throw` — they
  are direct `status = .failed(...)` assignments.

**`try?` site (silent swallow):**
- `AppleSpeechLiveTranscriptionEngine.swift:156` — `try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)`
  inside `cleanup()`. Justification not stated; rationale (likely): cleanup runs on stop /
  termination and a deactivation failure has no recovery path because the session is shared
  with `AppleAudioInputService`. Findings-only: this is the lone untyped-throw swallow on
  the ASR path and is **not** observable to a caller.

**Boundary (App-side):**
- `Dspeech/App/LiveTranscriptionViewModel.swift:22-25` —
  `var lastErrorMessage: String? { if case let .failed(message) = status { return message } else { return nil } }`.
  Direct passthrough of the engine's failure string — no `describe(_:)` mapping, no
  localization. The raw English/AVFoundation-localized text reaches the UI unmodified.

**Cross-service crossings:** none directly, but the ASR engine and the audio-source picker
(`AppleAudioInputService`) **share** the process-wide `AVAudioSession.sharedInstance()`:
both call `setCategory(.record, mode: .measurement, options: [.duckOthers])` and
`setActive(true, ...)` — see `AppleSpeechLiveTranscriptionEngine.swift:78-79` vs
`AudioInputService.swift:318` / `:326`. A failure originating in one subsystem can therefore
produce a failure visible to the other; both are typed-/string-locally but neither inspects
the other's state. Findings-only: this is the only structural cross-subsystem coupling.


## 5. Settings — no error type

`Dspeech/Core/Settings/PrivacySettings.swift` declares no `Error` type and contains zero
`throws` sites. `PrivacySettingsStorage` (line 27-30) is a non-throwing protocol. Load
failure is encoded as the fail-safe default return `.localOnly`
(`PrivacySettings.swift:42-46`); save failure is undetectable — `UserDefaults.set(_:forKey:)`
is fire-and-forget here, unlike `UserDefaultsFirstRunStateStore.markFirstRunCompleted()`
which performs a readback. Findings-only: this is a deliberate asymmetry — the privacy mode
is "soft" state that the next launch can recompute from the toggle, whereas the first-run
completion bit gates a destructive UI state and must be persisted hard.

`AudioCaptureService.swift` (12 LoC, protocol-only) and `SpeechRecognitionService.swift`
(5 LoC, protocol-only) likewise declare no error types; their `AsyncThrowingStream<_, Error>`
surface accepts whatever a concrete adapter throws, untyped.


## 6. Gap analysis

### 6.1 Services with no defined error type
- **`AppleSpeechLiveTranscriptionEngine`** (`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`)
  — relies on `LiveTranscriptionStatus.failed(String)` string carriage. Proposed enum name
  (for a future remediation task — **not** a fix prescription here):
  `LiveTranscriptionError` with cases `.speechPermissionDenied`, `.microphonePermissionDenied`,
  `.recognizerUnavailable(locale: String)`, `.audioSessionUnavailable(String)`,
  `.engineStartFailed(String)`. Each currently corresponds to an existing string literal in
  the file: lines 41, 46, 53, 63 (the "start-failed:" prefix collapses both
  `beginAudioSession()` and `audioEngine.start()` paths).
- **`AudioCaptureService`** — protocol-only stub for a future capture seam; failure type
  is `Error` because the protocol exists but no concrete adapter does yet. Naming a typed
  error today would be speculative.
- **`SpeechRecognitionService`** — same posture: protocol-only stub, no concrete adapter,
  no callers. `AsyncThrowingStream<TranscriptSegment, Error>` is the only failure channel.
- **`PrivacySettingsStorage`** — non-throwing by deliberate design (see §5); no error type
  proposed.

### 6.2 Errors that lack `errorDescription`
**All three** typed enums lack `LocalizedError` conformance:
- `AudioInputServiceError` — declared `Error, Equatable, Sendable` (`AudioInputServiceProtocol.swift:101`).
- `TranslationServiceError` — declared `Error, Equatable, Sendable` (`TranslationServiceProtocol.swift:28`).
- `FirstRunCoordinatorError` — declared `Error, Equatable, Sendable` (`FirstRunCoordinatorProtocol.swift:34`).

Consequence: nothing else in the codebase can call `error.localizedDescription` and get
useful text — the raw debug description (`"audioSessionUnavailable(...)"`) is what surfaces
under any non-app catch. Today this is fine because the only consumers are the App-side
`describe(_:)` switches (`SettingsSheet+Sections.swift:145`, `:271`; `FirstRunView.swift:139`)
which exhaust every case. A future caller that bypasses those switches — e.g. logging —
will currently surface raw debug text. Findings-only.

The ASR string-carriage error reaches the UI as raw `String` with **no** Russian translation
or grouping; this is also a `localizedDescription`-shaped gap, just expressed at the status
layer rather than the `LocalizedError` layer (see `LiveTranscriptionViewModel.swift:22-25`
and the only consumer of that property, which is part of the App and out of scope to enumerate
here).

### 6.3 Cross-service originations
None observed. Each typed error stays inside its declaring subsystem. The two boundaries that
do **map** an external (Apple) error onto an internal typed enum are explicit and live in
exactly one place each:
- `TranslationService.swift:96-117` (Apple `TranslationError` → `TranslationServiceError`).
- `SettingsSheet.swift:77-92` + `:157-177` (App-side parallel mapping table for the
  `.translationTask`/`prepareTranslation()` flow).

These two are not "cross-service" in the sense the spec asks (service A's error reaching
service B); they are intra-Translation. **However**: the duplication of the Apple-error
mapping across the two files is a smell — if Apple adds a new `TranslationError` case (e.g.
a future iOS 27 case), both tables need updating. The current pair handles disjoint subsets
(`AppleTranslationService.translate(_:from:into:)` enumerates seven static cases vs
`SettingsSheet.swift` `.translationTask` catches three), so the duplication is partial, not
full. Findings-only.

### 6.4 `try?` / `try!` audit
- `try!` — **zero occurrences** anywhere in the in-scope code.
- `try?` — **two occurrences**:
  - `AudioInputService.swift:92` — `try? await Task.sleep(for: duration)` inside the
    `defaultSleep` injection. Swallows `CancellationError` only — the established Swift
    idiom for "cancellation is the intended exit." Not a candidate to surface.
  - `AppleSpeechLiveTranscriptionEngine.swift:156` — `try? AVAudioSession.sharedInstance().setActive(false, ...)`
    inside `cleanup()`. Swallows an AVFoundation deactivation failure during stop /
    termination teardown. **Candidate** to consider surfacing to the user (or at least
    logging) because: (a) `AVAudioSession` is shared with `AppleAudioInputService`, so a
    failed deactivation has cross-subsystem consequences; (b) `cleanup()` runs on both
    normal `stop()` and stream `onTermination`, so a failure here is otherwise invisible.

### 6.5 Stream-failure type erasure
- `AudioInputService.levels() -> AsyncThrowingStream<AudioInputLevel, Error>` —
  `AudioInputServiceProtocol.swift:157`. Apple's `AsyncThrowingStream` has no typed-failure
  variant in iOS 26, so the typed `AudioInputServiceError` is widened to `Error` at the seam.
  The catch site at `SettingsSheet+Sections.swift:117-124` is therefore untyped and produces
  one generic Russian string instead of switching on cases. See §1.3.
- `AudioCaptureService.samples() -> AsyncThrowingStream<AudioSampleBuffer, Error>` —
  `AudioCaptureService.swift:11`. Same constraint, but the protocol has no adopter today, so
  there is no boundary to inspect.
- `SpeechRecognitionService.transcribe(_:) -> AsyncThrowingStream<TranscriptSegment, Error>` —
  `SpeechRecognitionService.swift:4`. Same constraint, same posture (no adopter today).

### 6.6 Unrouted typed-throws
The `AppleTranslationService.translate(_:from:into:)` path is fully typed
(`TranslationService.swift:79-117`) and reachable from the wiring
`LocalTranslationService(backend: AppleTranslationService())` at `ContentView.swift:21`, but
**no App-side `try`-caller invokes it**. The only consumer of any `TranslationService` method
is `TranslationSettingsSection.refreshStatus()` (`SettingsSheet+Sections.swift:248-254`)
which calls the non-throwing `availability(_:_:)`. So the typed seven-case error vocabulary
of `.translate(_:from:into:)` is currently unreachable from the UI. Findings-only — this is
the per-segment translation gap the next slice is expected to close.


## 7. UNKNOWN / verify-before-adoption notes

- The repo uses Swift 6 typed-throws (`throws(SomeError)`) — verified by the explicit
  protocol signatures cited above (`AudioInputServiceProtocol.swift:138`,
  `TranslationServiceProtocol.swift:94-98`, `FirstRunCoordinatorProtocol.swift:74`). Typed
  throws were stabilized in Swift 6.0; the repo `CLAUDE.md` declares "Swift 6 strict
  concurrency, iOS 26+, Xcode 26", consistent with this usage. **UNKNOWN — verify before
  adoption**: whether Swift 6's typed-throws allows mixing with `AsyncThrowingStream<_, E>`
  where `E` is a concrete error type (rather than the untyped `Error`). Apple's
  `AsyncThrowingStream` initializer in this codebase is always called with `Error` as the
  failure parameter (`AudioInputService.swift:131-132`); whether a typed alternative exists
  in iOS 26 has not been verified here.

- `Translation.TranslationError` is treated as a `struct` with `static let` cases plus `~=`
  matching (per `TranslationService.swift` DocC-cite line 27, `SettingsSheet.swift` DocC-cite
  line 114). The `catch TranslationError.X` syntax at lines 100-110 is the Swift pattern
  that consumes this `~=` overload. Verified against Apple DocC URLs cited in those files
  (2026-05-19) per the repo's anti-hallucination policy.


## 8. Summary counts

- Typed-throws error enums declared in-scope: **3** (`AudioInputServiceError`,
  `TranslationServiceError`, `FirstRunCoordinatorError`).
- Untyped string-error encodings in-scope: **1** (`LiveTranscriptionStatus.failed(String)`).
- `LocalizedError` conformances in-scope: **0**.
- App-side `describe(_:)` boundary functions: **3** (`SettingsSheet+Sections.swift:145`,
  `:271`; `FirstRunView.swift:139`).
- `try?` swallows in-scope: **2** (`AudioInputService.swift:92` — cancellation, safe;
  `AppleSpeechLiveTranscriptionEngine.swift:156` — deactivation, candidate to surface).
- `try!` in-scope: **0**.
- `Result<_, _>` in-scope: **0**.
- Cross-service error originations (service A error reaching service B catch): **0**.
- Shared mutable system surface where cross-subsystem coupling could surface failures
  without crossing the type system: **1** (`AVAudioSession.sharedInstance()` shared between
  `AppleSpeechLiveTranscriptionEngine` and `AppleAudioInputService` / `MeteringSession`).
