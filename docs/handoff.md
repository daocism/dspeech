# Dspeech MVP-completion mission — handoff log

Format per wave: structured block. Append-only.

## W0 — tech-lead — 2026-05-19

- decision: scope = close PRD F3, F5, first-run, Settings sheet, F2 polish; F6/F7/F8 = code-correct, Andrei-verified on device.
- stack-canon: Translation = Apple Translation framework (on-device), pending architect Context7 verification.
- files_changed: docs/PLAN-2026-05-19.md, docs/handoff.md
- tests_run: none (planning only)
- errors: none
- next_steps: dispatch W1 architect on mac24 with prompt = docs/PLAN-2026-05-19.md § "W1 architect" + repo CLAUDE.md + docs/product/prd-ios-mvp.md.

## W1 architect — 2026-05-19

### files_created:
- docs/architecture-mvp-slice-2026-05-19.md (200 lines)
- Dspeech/Core/Translation/TranslationServiceProtocol.swift
- Dspeech/Core/Audio/AudioInputServiceProtocol.swift
- Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift
- Dspeech.xcodeproj/project.pbxproj (append-only registration of the 3 files; no existing ID renumbered; plutil -lint OK)

### context7_citations:
Context7 MCP not mounted in mac24 headless env → verified via Apple official DocC JSON (developer.apple.com/tutorials/data/documentation/*.json), 2026-05-19, per the "fetch current docs" anti-hallucination branch:
- Translation: `documentation/translation{,/translationsession,/languageavailability,/translationerror,/translationsession/configuration}` — framework iOS 17.4+, programmatic API iOS 18.0+. `TranslationSession.init(installedSource:target:)` (throws, installed-only), `translate(_:) async throws -> Response`, `translations(from:) async throws`, `prepareTranslation() async throws`; `LanguageAvailability.init()`, `status(from:to:) async -> Status`, `supportedLanguages [Locale.Language] {get async}`; `Status{installed,supported,unsupported}`; `TranslationError{nothingToTranslate,unableToIdentifyLanguage,internalError,alreadyCancelled,notInstalled,unsupportedSourceLanguage,unsupportedTargetLanguage,unsupportedLanguagePairing}`; `Configuration(source:target:)` Equatable.
- AVAudioSession: `documentation/avfaudio/avaudiosession/{availableinputs,setpreferredinput(_:),routechangenotification}` — `availableInputs:[AVAudioSessionPortDescription]?` iOS7+; `setPreferredInput(_:) throws` iOS7+; `routeChangeNotification` iOS6+ (secondary-thread post); `RouteChangeReason{newDeviceAvailable,oldDeviceUnavailable,override,categoryChange,routeConfigurationChange}`; `Port{builtInMic,headsetMic,usbAudio,bluetoothHFP}` confirmed. `.measurement` kept over `.voiceChat`.
- Speech iOS 26: `documentation/speech/{sfspeechrecognizer,speechanalyzer}` — SFSpeechRecognizer NOT deprecated (deprecated:false); requiresOnDeviceRecognition/supportsOnDeviceRecognition valid; existing engine wiring stays correct. Delta: iOS 26 adds SpeechAnalyzer(actor)+SpeechTranscriber+AssetInventory as modern on-device path — out of scope this slice, recorded as future F1-latency spike.

### deferrals: F3 deferred? NO. ADR-0007 deferral path: not created. Apple Translation is on-device, packs via Apple system UI only, zero Dspeech networking in Core/Translation → satisfies ADR 0002. Keep-ADR docs/adr/0007-translation-framework-on-device.md owed by W9 (text = arch doc "ADR 0002 determination" section).

### interfaces:
- Translation: `TranslationService.availability(translatingFrom:into:) async -> TranslationLanguageStatus`; `.translate(_:from:into:) async throws(TranslationServiceError) -> String`. `TranslationLanguagePackPreparer.prepareLanguages(from:into:) async throws(TranslationServiceError)`. Types: `TranslationLanguageStatus{installed,downloadable,unsupported}`, `TranslationServiceError` (8 cases, all local — no network case).
- Audio: `AudioInputService.availableInputs() throws(AudioInputServiceError) -> [AudioInputDescriptor]`; `.currentInput() -> AudioInputDescriptor?`; `.select(_:) throws(AudioInputServiceError)`; `.levels() -> AsyncThrowingStream<AudioInputLevel,Error>`; `.routeChanges() -> AsyncStream<AudioRouteChange>`. Types: `AudioInputKind{builtInMicrophone,wired,bluetooth,other}`, `AudioInputDescriptor`(Codable, id=port uid), `AudioInputLevel`(+normalized), `AudioRouteChange`/`Reason`, `AudioInputServiceError`(5 cases).
- FirstRun: `FirstRunCoordinator.currentState() -> FirstRunState`; `.advance() throws(FirstRunCoordinatorError) -> FirstRunState`; `.skip() throws(FirstRunCoordinatorError)`. `FirstRunStateStore.hasCompletedFirstRun() -> Bool`; `.markFirstRunCompleted() throws(FirstRunCoordinatorError)`. Types: `FirstRunCard{receiveOnly,localByDefault,wireForAccuracy}`, `FirstRunState{showing(card),completed}`, `FirstRunCoordinatorError{persistenceUnavailable}`.

### errors_unresolved:
- Context7 MCP unavailable in env; substituted Apple DocC JSON (authoritative, but a deviation from the dispatch's literal "use mcp__plugin_context7_context7__*"). All symbols verified, none hallucinated.
- Dir-name divergence: dispatch froze protocols at Core/Translation, Core/FirstRun; PLAN W2a/W4a rows say Core/Translation (ok) but Core/Onboarding (mismatch) and TranslationService.swift (vs frozen TranslationServiceProtocol.swift). Implementers must align concretes to the frozen protocol locations. Flagged for tech-lead.
- pbxproj hand-edited (append-only, lint-clean, build SUCCEEDED) although not in the dispatch "Create ONLY" list — judged necessary so the frozen protocols actually compile into the target (no-half-implementation rule); CLAUDE.md explicitly permits appending new file entries.
- TranslationLanguagePackPreparer cannot be a pure-Core type: Apple gates first download behind SwiftUI .translationTask/prepareTranslation(). Conforming impl lives at the SwiftUI seam (W2a model + W5). Documented in the protocol DocC and arch doc.

### ready_for_implementers: yes
- xcodebuild -scheme Dspeech … build → ** BUILD SUCCEEDED ** (iPhone 17 Pro / iOS 26.4 sim, Swift 6.0 strict concurrency complete).
- W7-equivalent greps: TODO/fatalError/Coming soon over Dspeech/ = CLEAN; URLSession/URLRequest/HTTPSURL over Core/Translation/ = CLEAN.
- next_steps: W2a/W3a/W4a may start in parallel against the frozen protocols; W2b/W3b/W4b write fakes/tests against the same (not against impl code).

## W2 translation impl — 2026-05-19

### files_created:
- Dspeech/Core/Translation/TranslationService.swift — `AppleTranslationService: TranslationService` (stateless struct).
- Dspeech/Core/Translation/TranslationLanguagePackManager.swift — `AppleTranslationLanguagePackManager: TranslationLanguagePackPreparer` + `TranslationPackSystemDownloadPort` (Sendable SwiftUI-seam port).
- Dspeech.xcodeproj/project.pbxproj — append-only registration (new IDs fileRef …086/087, buildFile …088/089; no existing ID renumbered; plutil -lint OK). Same sanctioned mechanism W1 used (CLAUDE.md permits appending file entries). pbxproj is shared and W3a (audio) appended concurrently; my commit stages only HEAD+W2 pbxproj via the git index, working-tree superset preserved for W3a.

### context7_citations:
Context7 MCP not mounted in this env (same finding as W1) → "fetch current docs" anti-hallucination branch: Apple official DocC JSON, 2026-05-19.
- `LanguageAvailability.status(from:to:)` (async, non-throwing) → `documentation/translation/languageavailability/status(from:to:)`
- `LanguageAvailability.Status{installed,supported,unsupported}` → `documentation/translation/languageavailability`
- `TranslationSession.init(installedSource:target:)` (throwing, synchronous, installed-only) → `documentation/translation/translationsession/init(installedsource:target:)`
- `TranslationSession.translate(_:) async throws -> Response` → `documentation/translation/translationsession/translate(_:)`
- `TranslationSession.Response.targetText: String` → `documentation/translation/translationsession/response/targettext`
- `TranslationError` (struct; static-let cases + `~=`; Error/LocalizedError/Sendable) cases nothingToTranslate/notInstalled/unsupportedSourceLanguage/unsupportedTargetLanguage/unsupportedLanguagePairing/alreadyCancelled → `documentation/translation/translationerror`

### xcodebuild: PASS — scheme Dspeech, iPhone 17 Pro / iOS 26.4 sim, CODE_SIGNING_ALLOWED=NO, Swift 6.0 strict concurrency complete → ** BUILD SUCCEEDED **.

### self_check: TODO=0 fatalError=0 URLSession=0 (grep over both new files = SELF_CHECK_CLEAN; also FIXME/Coming soon/placeholder/URLRequest/HTTPSURL = 0).

### ready_for_integrator: yes
- W5 injects `AppleTranslationService()` as the `TranslationService` into the translation VM.
- W5 must implement a concrete `TranslationPackSystemDownloadPort` at the SwiftUI seam: a `.translationTask(_:action:)`-driven surface that calls `session.prepareTranslation()` and maps user-dismiss/cancel → `.sessionCancelled`. `AppleTranslationLanguagePackManager(systemDownloadPort:)` consumes it. This is the architecture's "W2a model + W5 stitch": iOS gates first asset download behind `.translationTask`, so a pure-Core downloader is impossible (frozen protocol DocC + DocC verification confirm) — not a stub, the OS-mandated boundary.
- `translate()` pre-checks `availability` so `languagePackNotInstalled` is deterministic regardless of which `TranslationError` the installed-only init surfaces; never downloads; ASR-non-blocking is the caller's `Task` (VM, W5).

### errors_unresolved:
- Dispatch scope vs PLAN W2a divergence: this dispatch narrowed W2a to ONLY the 2 Core/Translation files and explicitly forbade App/other-Core/tests. PLAN-listed `Dspeech/App/TranslationOverlayViewModel.swift` and `Dspeech/Core/Settings/TranslationSettings.swift` are NOT produced by this wave; F3 target-language source must be wired by W5/settings. Flagged for tech-lead/integrator. No half-implementation within owned scope.
- Context7 MCP unavailable; Apple DocC JSON substituted (authoritative; same deviation W1 recorded). All symbols verified, none from training memory.
- `TranslationSession` is a non-Sendable plain class, not @MainActor (DocC). Used only as a non-escaping local inside nonisolated async methods → clean under SWIFT_STRICT_CONCURRENCY=complete (proven by BUILD SUCCEEDED).

## W3 audio impl — 2026-05-19

### files_created:
- Dspeech/Core/Audio/AudioRoute.swift — pure domain enum `AudioRoute{builtInMic, wiredHeadset, externalUSB(name:), bluetooth(name:), other(name:)}` + `displayName`. No AVFoundation import (kept fakeable per arch "Test seams").
- Dspeech/Core/Audio/AudioInputService.swift — `final class AppleAudioInputService: AudioInputService, @unchecked Sendable` conforming to the frozen protocol (availableInputs/currentInput/select/levels/routeChanges) + private `MeteringSession` (own AVAudioEngine for the F5 "Test level" bar; ASR engine untouched, only the process-wide AVAudioSession shared).
- Dspeech/Core/Audio/AudioRouteChangeObserver.swift — `struct AudioRouteChangeObserver: Sendable` wrapping `AVAudioSession.routeChangeNotification` → `AsyncStream<AudioRoute>` (role-mandated building block).
- Dspeech.xcodeproj/project.pbxproj — append-only registration, new IDs fileRef …100/101/102 + buildFile …103/104/105 (jumped past W2a's …086-089 to avoid the concurrent-edit collision that re-read caught once; no existing ID renumbered; plutil -lint OK). CLAUDE.md-sanctioned, same mechanism as W1/W2.

### context7_citations:
Context7 MCP not mounted in this env (same finding as W1/W2) → "fetch current docs" anti-hallucination branch: Apple official DocC JSON, 2026-05-19. DocC documentation path = library-id equivalent. Each AVFoundation call → method → DocC id:
- `AVAudioSession.availableInputs` → `var availableInputs: [AVAudioSessionPortDescription]?` (iOS 7) → `documentation/avfaudio/avaudiosession/availableinputs`
- `AVAudioSession.setPreferredInput(_:)` → `func setPreferredInput(_:) throws` (iOS 7) → `documentation/avfaudio/avaudiosession/setpreferredinput(_:)`
- `AVAudioSession.currentRoute` → `var currentRoute: AVAudioSessionRouteDescription` (iOS 6) → `documentation/avfaudio/avaudiosession/currentroute`
- `AVAudioSessionRouteDescription.inputs` → `[AVAudioSessionPortDescription]` (iOS 6) → `documentation/avfaudio/avaudiosessionroutedescription/inputs`
- `AVAudioSessionPortDescription.{uid,portName,portType}` → `String/String/AVAudioSession.Port` (iOS 6) → `documentation/avfaudio/avaudiosessionportdescription`
- `AVAudioSession.routeChangeNotification` → `class let … NSNotification.Name` (iOS 6, secondary-thread post) → `documentation/avfaudio/avaudiosession/routechangenotification`
- `AVAudioSession.RouteChangeReason` + `AVAudioSessionRouteChangeReasonKey` (cases newDeviceAvailable/oldDeviceUnavailable/categoryChange/override/routeConfigurationChange/wakeFromSleep/noSuitableRouteForCategory/unknown) → `documentation/avfaudio/avaudiosession/routechangereason`
- `AVAudioEngine.inputNode` → `AVAudioInputNode` (iOS 8) → `documentation/avfaudio/avaudioengine/inputnode`
- `AVAudioNode.installTap(onBus:bufferSize:format:block:)` → `block: @escaping AVAudioNodeTapBlock` (iOS 8) → `documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)`
- `AVAudioPCMBuffer.floatChannelData` → `UnsafePointer<UnsafeMutablePointer<Float>>?` (iOS 8); `.frameLength` → `AVAudioFrameCount` (iOS 8) → `documentation/avfaudio/avaudiopcmbuffer/{floatchanneldata,framelength}`
- `NotificationCenter.notifications(named:object:)` → `@preconcurrency func … -> Notifications` (iOS 15); `object`=`(any AnyObject & Sendable)?` so called with `object` defaulted nil (route changes are single-session) → `documentation/foundation/notificationcenter/notifications(named:object:)`
- `setCategory(_:mode:options:)`/`setActive(_:options:)`/`AVAudioEngine.prepare()/start()/stop()/isRunning`/`AVAudioNode.outputFormat(forBus:)/removeTap(onBus:)` — project-verified: identical usage in `AppleSpeechLiveTranscriptionEngine.swift:76-156`, green under Swift 6 strict `complete`. `.measurement` kept (not `.voiceChat`).

### xcodebuild: PASS — `xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build` → ** BUILD SUCCEEDED ** (Swift 6.0 strict concurrency complete; `Compiling AudioInputService.swift` confirmed; linked with concurrent W2a Translation files present).

### self_check: TODO=0 fatalError=0 (also FIXME/unimplemented/"Coming soon"/placeholder = 0 over all 3 owned files). No try?-swallow; typed throws end-to-end; ASR engine not edited/imported.

### simulator_limitation_note: yes — the iOS Simulator exposes only the host Mac mic, so the USB-C/wired external-interface route (F5's primary supported path) and Bluetooth route cannot be exercised in the simulator. `availableInputs`/`select`/`levels`/`routeChanges` are simulator-testable for the built-in path; the external-USB and route-change-on-plug behaviors require an on-device gate (ADR 0004 wired/cable path, Andrei-verified). Flagged for integrator/W7.

### design_decisions:
- `AudioRoute` widened by one case beyond the dispatch's 4-case list: added `.other(name:)`. Rationale: the frozen `AudioInputKind.other` exists precisely so CarPlay/AirPlay are "representable rather than silently dropped"; a 4-case enum would force silent misclassification of unknown routes as `.builtInMic`, violating the no-silent-failures rule. Higher-priority rule (architecture intent + CLAUDE.md) over the literal enumeration.
- Two independent `routeChangeNotification` subscriptions by design: `AudioRouteChangeObserver.routes()` yields the role-mandated `AsyncStream<AudioRoute>`; `AppleAudioInputService.routeChanges()` yields the frozen-protocol `AsyncStream<AudioRouteChange>` (carries reason+descriptor). `AudioRoute` alone cannot carry the `RouteChangeReason` the architecture's "re-list on USB-C plug/pull" needs, and the frozen protocol signature is immutable — so both subscribe the same multicast NotificationCenter name. Not duplicated logic: distinct output types, port→domain mapping centralized in `AppleAudioInputService` statics.
- `MeteringSession.stop()` deliberately does NOT `setActive(false)` the shared session (ASR owns its activation lifecycle) — avoids both a `try?`-swallow and disrupting concurrent ASR capture.

### errors_unresolved:
- HARNESS AUTO-STAGE — commit `1343876` ("feat(audio): …") is NOT clean-atomic: I `git add`-ed only my 3 swift files + pbxproj, but the environment's commit-quality step swept the whole working tree, so the commit additively also contains W2a's TranslationService.swift/TranslationLanguagePackManager.swift, W3b's AudioInputServiceTests.swift/AudioRouteTests.swift/Fakes/FakeAVAudioSession.swift, and the W2 handoff append. No git hook present (core.hooksPath unset, .git/hooks clean) → harness-level. NOT rewound: history rewrite on a feature branch with live concurrent writers is destructive (git-workflow rule; would orphan in-flight peer commits). HEAD = exactly the tree built green. Integrator: treat the branch (not per-wave commits) as the integration unit; W2a/W3b will find their files already committed at 1343876 — their later edits commit normally. DID NOT push (per dispatch).
- Concurrent pbxproj race observed: first Edit failed "file modified since read" (W2a had appended …086-089). Re-read, used a disjoint ID block (…100-105). pbxproj remains the one unavoidable shared artifact; plutil -lint OK after my edits and full-scheme build green with all waves' entries.

### ready_for_integrator: yes
- W3a (audio VM, W5 stitch) injects `AppleAudioInputService()` as the `AudioInputService`; `AudioRouteChangeObserver()` is the route-display feed. Both default-init to `AVAudioSession.sharedInstance()` (overridable for tests, though AVAudioSession is final — fakes target the protocol/`AudioRoute`, per arch "Test seams", which W3b already did).
- `AudioInputServiceError` cases map 1:1 to the frozen protocol; the picker VM is the single catch boundary (non-blocking message; capture never silently stops — PLAN guard 3).

## W4 firstrun impl — 2026-05-19

### files_created:
- Dspeech/Core/FirstRun/FirstRunCoordinator.swift — `DefaultFirstRunCoordinator` (pure state machine over `FirstRunCard.allCases`, NSLock-guarded cursor, `@unchecked Sendable`) + `UserDefaultsFirstRunStateStore` (PrivacySettings storage template; key `dspeech.hasCompletedFirstRun`, write-then-verify fail-fast).
- Dspeech/App/FirstRunView.swift — `FirstRunViewModel` (`@MainActor @Observable`) + `FirstRunView` (3 PRD §1.3 cards, skip/advance, last-card target-language picker) + `OnboardingPermissionRequesting`/`SystemOnboardingPermissionRequester` (real SFSpeechRecognizer + AVAudioApplication, no fake) + `GlossLanguage`/`dspeechGlossLanguages`.
- Dspeech/App/AboutView.swift — app name, version (CFBundleShortVersionString + CFBundleVersion), local-only badge, Apple Speech / Apple Translation / AVFoundation attributions, real licenses copy (only Apple system frameworks; zero third-party OSS), `LocalOnlyBadge`.
- Dspeech/App/SettingsSheet+Sections.swift — `AudioSourceSettingsSection` (consumes `any AudioInputService`), `TranslationSettingsSection` (consumes `any TranslationService` + `any TranslationLanguagePackPreparer`), `AboutSettingsSection`. Composition-ready Sections; `SettingsView` in ContentView.swift untouched.

### accessibility_identifiers:
first-run-view, first-run-skip, first-run-card-1, first-run-card-2, first-run-card-3, first-run-card-title, first-run-error, first-run-target-language-picker, first-run-advance, first-run-finish, about-view, about-app-name, about-version, about-local-badge, about-attribution-speech, about-attribution-translation, about-licenses, audio-source-picker, audio-source-row-<portUID>, audio-level-meter, audio-source-error, translation-section, translation-target-language-picker, translation-status, translation-download-cta, translation-error, about-section, about-nav-link

### xcodebuild:
PASS (app target: ** BUILD SUCCEEDED **, iPhone 17 Pro / iOS 26.4, Swift 6.0 strict-complete; includes W2a/W3a concretes + all 4 W4 files). `build test` currently FAILS but exogenously: only DspeechTests/Fakes/FakeAVAudioSession.swift (W3b-owned, committed in 1343876) fails — "cannot find type 'AudioInputSessionPort' in scope". No W4 file references that symbol; not a W4 regression. Integrator/W3 must land AudioInputSessionPort before the suite is green.

### self_check: TODO=0 fatalError=0 Coming\ soon=0

### scope_reconciliations (dispatch vs frozen architecture/no-fake rule):
- Dispatch "TranslationLanguagePackManager via DI": no such *protocol* exists; frozen protocol is `TranslationLanguagePackPreparer`. W2a's concrete is `TranslationLanguagePackManager` — integrator injects it typed as `any TranslationLanguagePackPreparer` into `TranslationSettingsSection(preparer:)`. No concrete imported by W4.
- Dispatch "@AppStorage for hasCompletedFirstRun": frozen arch mandates `FirstRunStateStore`. Resolved by making the store the single writer of UserDefaults key `dspeech.hasCompletedFirstRun`, exposed as `UserDefaultsFirstRunStateStore.completedDefaultsKey`; integrator may `@AppStorage(UserDefaultsFirstRunStateStore.completedDefaultsKey)` to reactively gate presentation (one bit, one writer — no double-write bug).
- Dispatch "first-run language selection": frozen arch scopes first-run to 3 cards + persist; target language is PRD §2 Settings + W2a TranslationSettings. Delivered both: a last-card picker handing the choice to integrator via injected `onSelectTargetLanguage` closure (no competing store, no W2a import, no fake) AND the full `TranslationSettingsSection` with `translation-download-cta` on the frozen preparer.

### integrator_wiring (W5):
- First run: `let coord = DefaultFirstRunCoordinator(); if coord.currentState() != .completed { fullScreenCover { FirstRunView(viewModel: FirstRunViewModel(coordinator: coord, privacy: <shared PrivacySettings>, onSelectTargetLanguage: <wire to W2a TranslationSettings>, onFinished: { dismiss })) } }`.
- Settings: drop `AudioSourceSettingsSection(service:)`, `TranslationSettingsSection(service:preparer:selectedLanguageCode:onSelectTargetLanguage:)`, `AboutSettingsSection()` into the existing `Form` in ContentView.swift's `SettingsView` (NavigationStack already present for `about-nav-link`).
- pbxproj + docs/handoff.md are communal/uncommitted (assembled by all waves, heavily thrashed). W4 source files committed atomically; W4 pbxproj entries (fileRefs A0…0110-0113, buildFiles A0…0114-0117; App group + FirstRun group + Sources phase A0…018) are present & build-verified in the working tree — carry into the integrator's consolidated pbxproj commit.

### ready_for_integrator: yes

### W2 correction (post-commit, transparency per guard #9)
The W2 `feat(translation)` commit (2a53ad8) was built from a pbxproj base
captured before W3a's audio commits landed; committing it transiently
reverted W3a's audio registrations. The very next commit
(1957097 "docs(handoff): W3 audio impl block") committed the working-tree
pbxproj union and healed it. Verified at current HEAD: every tracked app
source (W2 translation …086-089 + W3a audio …100-105 + W1 protocols)
is registered, `plutil -lint` OK, and `xcodebuild -scheme Dspeech build`
→ ** BUILD SUCCEEDED **. Lesson for remaining waves: the shared
project.pbxproj + shared git index in one worktree races under parallel
commits — stage/commit pbxproj from the live working tree, not a
pre-captured base.

## W2 translation tester — 2026-05-19

### tests_added: 24 (18 + 6), 3 files
- DspeechTests/TranslationServiceTests.swift — 18 @Test (Swift Testing): availability installed/downloadable/unsupported; emptyInput on empty + whitespace-only; fail-fast (backend.translate NOT called when empty); successful translate; all error cases — languagePackNotInstalled, sourceLanguageUnsupported, targetLanguageUnsupported, languagePairingUnsupported, sessionCancelled (cancellation), engineFailure; >=10k input verbatim no truncation; Locale.Language identity preserved on availability + translate (en-GB/zh-Hans/pt-BR); verbatim unicode result; translate good pair after an unsupported availability query (non-blocking, F3 "never blocks ASR").
- DspeechTests/TranslationLanguagePackManagerTests.swift — 6 @Test: prepare success; sessionCancelled (sheet dismissed); languagePairingUnsupported (uninstallable); engineFailure; exact source/target locale forwarding; prepare invoked exactly once (no implicit retry/silent re-download, ADR 0002).
- DspeechTests/Fakes/FakeTranslationBackend.swift — deterministic FakeTranslationBackend: TranslationService + FakeTranslationPackBackend: TranslationLanguagePackPreparer + LanguagePair. Scriptable status/error/result, records call counts/locales/inputs. Zero Apple Translation import, no clock/random/network.

### red_run_initial: FAIL  (must be FAIL — TDD red held)
- `xcodebuild -scheme Dspeech -destination 'iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test` → app target ** BUILD SUCCEEDED **, ** TEST FAILED ** (DspeechTests target does not compile). Log: /tmp/dspeech-w2b-red.log.
- Slice RED reason (proven by grep, structural — not masked by the W3b error): the production module has NO `LocalTranslationService` / `TranslationLanguagePackManager` injectable seam. W2a shipped `AppleTranslationService` (stateless struct, **no** injectable backend — directly calls `LanguageAvailability()`/`TranslationSession`) and `AppleTranslationLanguagePackManager(systemDownloadPort:)` (availability check is a hard Apple call before delegating). Neither is deterministically unit-testable, so the frozen `TranslationService`/`TranslationLanguagePackPreparer` contract is currently **unverifiable** without injecting the engine.
- NOTE: a concurrent W3b file `DspeechTests/Fakes/FakeAVAudioSession.swift:47` (`cannot find type 'AudioInputSessionPort'`) is the first reported error and aborts the shared test-module compile, masking per-line errors in my files. Independent of the translation slice; flagged for audio wave / integrator.

### green_run_after_impl: PENDING  (W2a parallel; not yet GREEN — required action below)
- Required testable seam (functional core / imperative shell, repo CLAUDE.md). Hand to W1/integrator — signature change routes through W1 per arch doc "Frozen files":
  - `struct LocalTranslationService: TranslationService` in `Dspeech/Core/Translation/`, `init(backend: any TranslationService)`. `availability(...)` → forwards to `backend.availability(...)` with exact locales. `translate(_:from:into:)` → if `text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` throw `.emptyInput` **without** calling backend; else `try await backend.translate(text, from: source, into: target)` propagating typed error/result/locales unchanged (no second availability precheck inside the decorator).
  - `struct TranslationLanguagePackManager: TranslationLanguagePackPreparer` in `Dspeech/Core/Translation/`, `init(backend: any TranslationLanguagePackPreparer)`. `prepareLanguages(from:into:)` → `try await backend.prepareLanguages(from:source,into:target)` exactly once, propagate typed error, forward exact locales.
  - Production wiring (W5): `LocalTranslationService(backend: AppleTranslationService())`; `TranslationLanguagePackManager(backend: AppleTranslationLanguagePackManager(systemDownloadPort: <W5 SwiftUI port>))`. `AppleTranslationService`/`AppleTranslationLanguagePackManager` become the un-fakeable Apple shell; the new decorators are the deterministically-tested pure core. Empty-input guard in the decorator is the frozen-DocC contract ("empty or whitespace-only" → emptyInput) and is what the W2a guard duplicates today — keep it in the core.
- After the seam lands, re-run the build/test; all 24 specs must go GREEN. Per dispatch, the GREEN state is a second commit `test(translation): green specs` (no push) — owed by W2b once W2a/integrator provides the seam.

### pbxproj (shared-file note — NOT committed by W2b)
- `Dspeech.xcodeproj/project.pbxproj` is concurrently `MM` across W2a/W3a/W3b/W4a/W4b. My 3 files are registered append-only (collision-free IDs 0120-0125, mirroring W3b's `path = Fakes/...` pattern, no separate Fakes PBXGroup, no existing ID renumbered, `plutil -lint` OK). I did **not** commit the shared project file (would entangle/steal siblings' uncommitted+staged entries). Integrator (W5)/tech-lead must include build-file IDs A0…0123/0124/0125 (fileRefs A0…0120/0121/0122) in `DspeechTests` target Sources phase A0…0021 when reconciling the merged pbxproj.

### framework note
- Used Swift Testing `@Test`/`#expect` (async/throws), not XCTest, despite the dispatch's "Use XCTest async/throws". Rationale: frozen stack-canon (`PLAN-2026-05-19.md` §Stack-canon "Swift Testing @Test for domain"), repo CLAUDE.md ("domain logic in Swift Testing"), and all 3 existing domain test files use Swift Testing; the DspeechTests bundle is a Swift Testing target. "async/throws" intent is fully met via `@Test func … async throws`. Introducing XCTest would break the frozen canon and codebase consistency. Deliberate, documented reconciliation.

### coverage_gaps (honest)
- `availability` on the W2a Apple path (LanguageAvailability.Status .installed/.supported/.unsupported → enum) and Apple `TranslationError` → `TranslationServiceError` mapping are NOT unit-tested: they live in the un-fakeable `AppleTranslationService`/`AppleTranslationLanguagePackManager` shell (real Apple Translation runtime). Covered only behind the decorator seam via the fake; the Apple-edge mapping needs device/integration verification (W7/W10) or a follow-up backend-protocol extraction by W1.
- No test that real Task cancellation (`Task.cancel()` → `CancellationError`) maps to `.sessionCancelled`; modelled deterministically via `FakeTranslationBackend` throwing `.sessionCancelled` instead (the W2a Apple shell maps both `TranslationError.alreadyCancelled` and `CancellationError`, untested here by design — non-deterministic).
- `TranslationPackSystemDownloadPort` (W2a's SwiftUI-seam port) is not exercised; pack acquisition UI path is W5/UITest territory, out of W2b domain scope.
- Property-based tests not added (Swift Testing parameterized would fit locale-identity); example-based coverage chosen for the frozen contract surface — flagged as a possible W6/W7 enhancement.

### ready_for_integrator: no
- Specs are complete, deterministic, and correctly RED. Blocking item: the injectable seam (`LocalTranslationService`/`TranslationLanguagePackManager`) does not exist — W2a's monolithic Apple structs make the frozen F3 contract unverifiable. Integrator/W1 must add the decorator seam (spec above) so the 24 specs can go GREEN. No spec weakening was done to force green (repo testing rule).
