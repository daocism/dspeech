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
