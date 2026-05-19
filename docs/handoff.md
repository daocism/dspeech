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
