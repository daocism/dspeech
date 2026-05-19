# Receive-only architecture — evidence dossier substantiating ADR 0002

Forensic audit substantiating (or refuting) the "receive-only, no transmission"
guarantee that anchors `docs/adr/0002-privacy-local-only-default.md` and the
marketing positioning in `docs/product/launch-positioning.md`. This dossier is
the artefact Andrei can paste into a privacy policy or App Store privacy
questionnaire when asked "where in the code is the no-transmission guarantee
proven?"

State of the world: HEAD `56f261c` on `feat/mvp-completion-2026-05-19`,
captured 2026-05-20.

---

## 1. Threat model framing

"Receive-only" means concretely: **no Dspeech-originated outbound bytes of any
class** — no outbound audio (raw or compressed PCM), no outbound transcript
text, no outbound translation strings, no outbound metadata (segment timings,
confidences, language codes), no outbound telemetry (crash reports, analytics
events, ping/heartbeat), no outbound bug reports.

"Receive-only" does **not** mean: App Store update fetch (Apple's responsibility,
out of process), iOS-level telemetry surfaced via Settings → Privacy → Analytics
(OS-owned), Apple Translation framework's first-time language-pack download
(Apple-owned transport, the same class as the keyboard/dictation model fetch;
ADR 0002 carve-out documented inline at
`Dspeech/Core/Translation/TranslationServiceProtocol.swift:67-70` and
`Dspeech/Core/Translation/TranslationLanguagePackManager.swift:26-27`).

Cited authority: `docs/adr/0002-privacy-local-only-default.md`.

---

## 2. Networking framework presence/absence

Every networking-capable framework reachable from a `Foundation`/UIKit/SwiftUI
iOS target enumerated and grepped. Search root: `Dspeech/App/**` and
`Dspeech/Core/**`. Search command for the table: `grep -rn '^import <Framework>'`
for the import column; per-symbol searches recorded in §3.

| Framework | Import found? | Symbol references inside Dspeech sources | Verdict |
|---|---|---|---|
| Foundation (URL / URLSession / URLRequest / URLProtocol) | `import Foundation` is present in 19 files, but **zero** references to `URL`, `URLSession`, `URLRequest`, `URLProtocol`, `URLSessionConfiguration`, `URLSessionWebSocketTask`, `URLSessionStreamTask`, `dataTask`, `uploadTask`, `downloadTask`, `webSocketTask`. Verified: `grep -rn '\bURL\b' Dspeech/` returns 0 hits. | None — see §3. | **unused** (Foundation is imported for `UUID`, `Date`, `UserDefaults`, `NotificationCenter`, `ProcessInfo`, `Locale`, `Duration`, `Task`, value types). |
| Network (`NWConnection`, `NWListener`, `NWPath`, `NWEndpoint`) | **no** `import Network` anywhere. Verified: `grep -rn '^import Network' Dspeech/` returns 0 hits. | None — see §3. | **unused** (framework absent from imports). |
| CFNetwork (`CFHTTPMessage`, `CFReadStream`, `CFWriteStream`, `CFHost`) | **no** `import CFNetwork` anywhere. | None. | **unused**. |
| CoreServices | **no** `import CoreServices` anywhere. | None. | **unused**. |
| BSD sockets (`socket(`, `connect(`, `bind(`, `send(`, `recv(`, `getaddrinfo`) | unreachable without `import Darwin` or `import SystemPackage`; both absent. | None. | **forbidden by absence**. |
| NSStream / `InputStream` / `OutputStream` (Foundation socket bridges) | Foundation is imported, but **zero** references to `NSStream`, `InputStream`, `OutputStream`. | None. | **unused**. |
| `CFSocket` | **no** import path; CoreFoundation socket primitives unreachable. | None. | **unused**. |
| DNS-SD (`DNSServiceRef`, `dnssd`) | **no** `import dnssd` anywhere. | None. | **unused**. |
| MultipeerConnectivity (`MCSession`) | **no** `import MultipeerConnectivity` anywhere. | None. | **unused**. |
| Speech (`SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`) | `import Speech` at `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:2`; permission request at `Dspeech/App/FirstRunView.swift` via `SFSpeechRecognizer.requestAuthorization`. | On-device recognizer pinned by `request.requiresOnDeviceRecognition = true` at `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:85`. | **used — on-device-only** (§4). |
| AVFoundation (`AVAudioEngine`, `AVAudioSession`) | `@preconcurrency import AVFoundation` at `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:1` and `Dspeech/Core/Audio/AudioInputService.swift:1`. | Audio capture and metering, never a transport. | **used — local audio capture only** (§4). |
| Translation (`TranslationSession`, `LanguageAvailability`) | `import Translation` at `Dspeech/App/SettingsSheet.swift:2`, `Dspeech/Core/Translation/TranslationService.swift:2`, `Dspeech/Core/Translation/TranslationLanguagePackManager.swift:2`. | `TranslationSession.translate(_:)` runs against installed on-device assets; `prepareTranslation()` invokes Apple's system download UI. | **used — Apple-owned asset transport, no Dspeech-originated networking** (§6). |

---

## 3. Outbound-byte audit

The literal grep tokens below were executed against the `Dspeech/` tree on
2026-05-20. Each grep is recorded with its raw count.

| Grep token (literal) | Match count in `Dspeech/` | Classification |
|---|---|---|
| `URL(` | 0 | `ABSENT — search returned no matches in this file class` |
| `URLSession` | 0 | `ABSENT` |
| `URLRequest` | 0 | `ABSENT` |
| `URLProtocol` | 0 | `ABSENT` |
| `URLSessionConfiguration` | 0 | `ABSENT` |
| `URLSessionWebSocketTask` | 0 | `ABSENT` |
| `URLSessionStreamTask` | 0 | `ABSENT` |
| `dataTask` | 0 | `ABSENT` |
| `uploadTask` | 0 | `ABSENT` |
| `downloadTask` | 0 | `ABSENT` |
| `webSocketTask` | 0 | `ABSENT` |
| `NWConnection` | 0 | `ABSENT` |
| `NWListener` | 0 | `ABSENT` |
| `NWPath` | 0 | `ABSENT` |
| `CFSocket` | 0 | `ABSENT` |
| `NSStream` | 0 | `ABSENT` |
| `InputStream` | 0 | `ABSENT` |
| `OutputStream` | 0 | `ABSENT` |
| `DNSService` | 0 | `ABSENT` |
| `getaddrinfo` | 0 | `ABSENT` |
| `socket(` | 0 | `ABSENT` |
| `\bURL\b` (whole-word) | 0 | `ABSENT` |
| `\bNetwork\b` (whole-word) | 0 | `ABSENT` |
| `http` (case-insensitive) | 1 — `Dspeech/Core/Translation/TranslationServiceProtocol.swift:68` ("open **no** sockets or HTTP clients") | `IGNORE — referenced in a docstring negation only` |
| `send(` (whole-word, network-context) | 0 | `ABSENT` |
| `connect(` (whole-word, network-context) | 0 | `ABSENT` |
| `bind(` (whole-word, network-context) | 0 | `ABSENT` |
| `cloud` (case-insensitive, all sources) | 8 — every hit is either privacy-mode label/UI copy (`PrivacySettings.swift`, `SettingsSheet.swift`, `AboutView.swift`) or a negation in a docstring (`TranslationServiceProtocol.swift:26,47,68-69`, `TranslationLanguagePackManager.swift:33,58`). | `IGNORE — strings/comments only, no call site` |
| `server` / `api.` / `packs.dspeech` (case-insensitive) | only `packs.dspeech.app` appears, inside a docstring negation at `TranslationServiceProtocol.swift:69` | `IGNORE — referenced in a docstring negation only` |

**Zero `REVIEW`-class findings.** No actual network call site exists in the
audited tree. Every textual match resolves to either a domain-value identifier
("URL" is unused — Foundation is imported for non-network value types only), a
privacy-mode label/UI string, or a docstring negation that documents the
absence of the corresponding primitive.

---

## 4. Audio path provenance

Entry point: `AVAudioEngine` is constructed at
`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:15` and (separately,
for level metering only) at `Dspeech/Core/Audio/AudioInputService.swift:399`.

Capture chain for ATC transcription
(`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`):

1. `audioEngine.inputNode.installTap(onBus:bufferSize:format:)` at line 95 —
   the only buffer-emitting entry point. The tap closure has exactly one
   consumer.
2. The `AVAudioPCMBuffer` is handed to
   `request?.append(buffer)` at line 97, where `request` is an
   `SFSpeechAudioBufferRecognitionRequest` (line 13, 83).
3. The recognition request is constrained on-device by
   `request.requiresOnDeviceRecognition = true` at line 85 — this is the literal
   token that pins the Speech framework off the network. Apple guarantees no
   off-device transport when this flag is set (Apple DocC
   `documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition`).
4. Recognition results return via the `SFSpeechRecognitionTask` callback at
   lines 104-122. The callback constructs a `TranscriptSegment` (lines 129-135)
   and yields it onto the in-process `AsyncStream<LiveTranscriptionEvent>` at
   line 136 (via `emit(_:)` at line 159).

**No buffer consumer is a networking API.** The only consumers of
`AVAudioPCMBuffer` in the tree are:

- `SFSpeechAudioBufferRecognitionRequest.append(_:)` —
  `AppleSpeechLiveTranscriptionEngine.swift:97`, on-device by line 85.
- `AppleAudioInputService.level(from:)` —
  `AudioInputService.swift:268-290`, a pure RMS/peak dBFS calculation that
  produces an `AudioInputLevel` value type for the on-screen meter and discards
  the buffer.

Microphone authorization is requested via `AVAudioApplication.requestRecordPermission`
(line 173) / the deprecated `AVAudioSession.sharedInstance().requestRecordPermission`
fallback (line 176-178). These are entitlement prompts, not transports.

---

## 5. Transcript path provenance

`TranscriptSegment` (`Dspeech/Core/Models/TranscriptSegment.swift`) is an
`Identifiable, Equatable, Sendable` value type. It has no `Codable` conformance
and no persistent-storage adapter.

Construction sites: `AppleSpeechLiveTranscriptionEngine.swift:129-135`
(production); demo-only fixtures in `TranscriptDemoViewModel.swift` flagged with
`source: .demo`.

Storage:

- `LiveTranscriptionViewModel.segments: [TranscriptSegment]` at
  `Dspeech/App/LiveTranscriptionViewModel.swift:7` — an in-memory `@Observable`
  array. No `Codable` round-trip, no persistence, no file write, no UserDefaults
  write. Wiped on `reset()` (line 38-41) and on process termination.
- The `partialText: String` field (line 8) is also in-memory only.

Persistent UserDefaults reads/writes across the entire audited tree (the
authoritative grep is in §9 token 4):

- `dspeech.privacy.mode.v1` — single `PrivacyMode` raw value
  (`PrivacySettings.swift:33,42,49`).
- `hasCompletedFirstRun` — single `Bool`
  (`FirstRunCoordinator.swift:16,25,29-33` and the launch-arg bridge at
  `DspeechApp.swift:37-49`).
- `dspeech.translation.targetLanguageCode` — single language-code `String`
  via `@AppStorage` at `ContentView.swift:10`.

**No transcript text, partial text, confidence, or timestamp is ever written
to UserDefaults, the filesystem, the keychain, or CloudKit.** The three stored
values above are all user preferences, not user-generated content.

---

## 6. Translation path provenance

Translated strings flow through `AppleTranslationService.translate(_:from:into:)`
at `Dspeech/Core/Translation/TranslationService.swift:79-117`. Path:

1. Empty-input guard (line 84-85) — local `String` operation.
2. Availability precheck via `LanguageAvailability().status(from:to:)`
   (line 87, 51) — Apple framework call, asynchronous, returns an enum.
3. Session construction:
   `TranslationSession(installedSource: source, target: target)` at line 97 —
   the **installed-only** initializer (DocC cited at lines 16-20). Apple does
   not download assets on this initializer; absence is detected up-front in
   step 2 and surfaces as `.languagePackNotInstalled`.
4. `session.translate(trimmed)` at line 98 — runs against installed on-device
   assets. The returned `response.targetText` is a plain `String` and is
   returned to the caller (line 99).
5. `TranslationError` cases are exhaustively mapped onto
   `TranslationServiceError` at lines 100-116. None of the typed cases
   represents a network or cloud condition by construction
   (`TranslationServiceProtocol.swift:23-27,28-58`).

The only call site that can reach Apple's first-time download UI is the
language-pack preparer, hosted at the SwiftUI seam
(`Dspeech/App/SettingsSheet.swift:77-92`,
`Dspeech/App/SettingsSheet.swift:119-178`). It is triggered exclusively from the
explicit "Download pack" CTA inside the Settings sheet (PRD §1 line 33), never
implicitly. The transport on that path is Apple's system download UI presented
by `TranslationSession.prepareTranslation()` — owned end-to-end by the OS
(documented carve-out in ADR 0002, restated at
`Dspeech/Core/Translation/TranslationLanguagePackManager.swift:26-27`,
`Dspeech/App/SettingsSheet.swift:117-118`).

No HTTP request, socket, or URL is constructed anywhere on the translation
path. The decorator `LocalTranslationService`
(`Dspeech/Core/Translation/TranslationService.swift:137-167`) and decorator
`TranslationLanguagePackManager`
(`Dspeech/Core/Translation/TranslationLanguagePackManager.swift:102-115`) do
not even import the `Translation` framework — they forward to an injected
backend.

---

## 7. Info.plist privacy declarations

`Info.plist` is generated from the per-target build settings
(`GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_KEY_*` at
`Dspeech.xcodeproj/project.pbxproj:141-142`). Read-only enumeration of every
privacy-relevant `INFOPLIST_KEY_*` declared for the `Dspeech` target:

- `INFOPLIST_KEY_NSMicrophoneUsageDescription` =
  "Dspeech использует микрофон для распознавания речи на устройстве. Аудио не
  покидает iPhone." — present, both Debug and Release.
- `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` =
  "Dspeech распознаёт речь на устройстве для отображения транскрипта." —
  present, both Debug and Release.

Absences (each one would be a red flag if present):

- **No `INFOPLIST_KEY_NSAppTransportSecurity`** entry of any shape: no
  `NSAllowsArbitraryLoads`, no `NSAllowsArbitraryLoadsInWebContent`, no
  `NSAllowsLocalNetworking`, no `NSExceptionDomains`. ATS is at its strict
  default for the whole binary.
- **No `INFOPLIST_KEY_NSLocalNetworkUsageDescription`** — the app cannot bind
  Bonjour/zeroconf or open LAN sockets without one on iOS 14+ even if it tried.
- **No `INFOPLIST_KEY_NSBonjourServices`** — no advertised services.
- **No `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`** / location keys —
  no location collection.
- **No `INFOPLIST_KEY_NSCameraUsageDescription`** / camera keys — no camera
  access.
- **No `INFOPLIST_KEY_NSUserTrackingUsageDescription`** — no ATT prompt
  configured, consistent with no analytics.
- **No `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`** is declared; ADR 0006
  forbids App Store submission from this repo, so this key is not yet
  applicable to a shipped binary, but its absence is consistent with the
  current no-network surface (no TLS endpoints to declare).
- **No `NSExtension`, no app extension targets, no `WKApp`, no `WidgetKit`
  configuration** in the pbxproj — only the `Dspeech` app target, the
  `DspeechTests` host-test target, and the `DspeechUITests` XCUITest target.

A future reviewer can re-read these declarations via:

```
plutil -p Dspeech.xcodeproj/project.pbxproj 2>/dev/null || \
  grep -nE 'INFOPLIST_KEY_NS[A-Za-z]+UsageDescription|INFOPLIST_KEY_NSAppTransportSecurity|ITSAppUsesNonExemptEncryption' \
    Dspeech.xcodeproj/project.pbxproj
```

---

## 8. Receive-only claim verdict

**SUBSTANTIATED — no `REVIEW`-class findings; no networking framework imports
detected; no networking primitive references found in `Dspeech/App/**` or
`Dspeech/Core/**`.**

Concretely: 0 hits for `URLSession`, `URLRequest`, `URLProtocol`, `NWConnection`,
`CFSocket`, `NSStream`, `dataTask`, `socket(`, `connect(`, `bind(`,
`DNSService`, and `\bURL\b` (whole-word). The Speech framework call path is
pinned to on-device by `requiresOnDeviceRecognition = true` at
`Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:85`. The Translation
framework call path uses the installed-only `TranslationSession` initializer
(line 97 of `TranslationService.swift`) and the SwiftUI-gated
`prepareTranslation()` path that delegates first-time asset acquisition to
Apple's system UI — an Apple-owned transport explicitly carved out by ADR 0002.

There are no caveats requiring `PrivacySettings.allowCloud == false` gating
because there is no code path that would *use* `allowCloud == true` to reach a
network — the toggle today only changes the on-screen `LOCAL`/`CLOUD` badge and
the privacy-mode raw value persisted to UserDefaults
(`PrivacySettings.swift:59-74`). If a cloud transport were added later, it
**must** be gated on `privacy.mode == .allowCloudFallback`; the future-proofing
greps in §9 will detect any introduction.

---

## 9. Future-proofing checklist

A future reviewer can re-run these literal greps against the audited tree;
each must return zero hits for the receive-only claim to remain
substantiated. Tokens chosen so that any plausible cloud-call introduction
must match at least one:

1. `grep -rn 'URLSession\|URLRequest\|URLProtocol\|URLSessionConfiguration\|URLSessionWebSocketTask\|URLSessionStreamTask\|dataTask\|uploadTask\|downloadTask\|webSocketTask' Dspeech/`
2. `grep -rn 'NWConnection\|NWListener\|NWPath\|NWEndpoint\|CFSocket\|NSStream\|InputStream\|OutputStream\|DNSService\|dnssd\|CFNetwork\|CFHTTPMessage\|CFReadStream\|CFWriteStream\|MultipeerConnectivity' Dspeech/`
3. `grep -rnE '^import (Network|CFNetwork|CoreServices|MultipeerConnectivity|GameKit|CloudKit|FirebaseCore|Sentry|AppCenter|Mixpanel|Amplitude|Segment|GoogleAnalytics)' Dspeech/`
4. `grep -rn 'requiresOnDeviceRecognition' Dspeech/` — must return at least one hit at `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift:85` with value `= true`. A missing flag or a `= false` flips the Speech path to a cloud transport.
5. `grep -rnE 'NSAppTransportSecurity|NSAllowsArbitraryLoads|NSExceptionDomains|NSBonjourServices|NSLocalNetworkUsageDescription' Dspeech.xcodeproj/project.pbxproj Dspeech/` — must return zero hits; any hit means an ATS exception or a LAN/Bonjour surface has been introduced.

---

## 10. Out of scope

This dossier captures only the Dspeech app's own code surface. It does
**not** prove:

- Apple iOS-level telemetry from the OS itself (managed via Settings → Privacy
  → Analytics & Improvements; OS-owned, opt-in by user).
- App Store binary update fetch (Apple-owned, out of process).
- iOS crash-report submission to Apple (off by default unless user opted into
  device-wide analytics sharing — no third-party crash reporter is configured
  by the app: §9 grep token 3 must keep returning zero `Sentry`/`Firebase`/etc.
  hits).
- Apple Translation framework's first-time language-pack download — explicit
  ADR 0002 carve-out, gated behind the user's "Download pack" tap inside
  Settings (PRD §1 line 33). Transport is Apple-owned and identical in class
  to the keyboard/dictation model fetch.
- Runtime debugger attachment, MetricKit reports, or any other OS-level
  mechanism that operates outside the app's compiled code.

These are OS-level mechanisms outside the app's code.

---

## 11. References

App sources cited above (all under `Dspeech/`):

- `Dspeech/App/ContentView.swift`
- `Dspeech/App/DspeechApp.swift`
- `Dspeech/App/FirstRunView.swift`
- `Dspeech/App/LiveTranscriptionViewModel.swift`
- `Dspeech/App/SettingsSheet.swift`
- `Dspeech/App/TranscriptDemoViewModel.swift`
- `Dspeech/Core/ASR/AppleSpeechLiveTranscriptionEngine.swift`
- `Dspeech/Core/ASR/LiveTranscriptionEngine.swift`
- `Dspeech/Core/ASR/SpeechRecognitionService.swift`
- `Dspeech/Core/Audio/AudioInputService.swift`
- `Dspeech/Core/Audio/AudioInputServiceProtocol.swift`
- `Dspeech/Core/Audio/AudioCaptureService.swift`
- `Dspeech/Core/Audio/AudioRoute.swift`
- `Dspeech/Core/Audio/AudioRouteChangeObserver.swift`
- `Dspeech/Core/FirstRun/FirstRunCoordinator.swift`
- `Dspeech/Core/FirstRun/FirstRunCoordinatorProtocol.swift`
- `Dspeech/Core/Models/TranscriptSegment.swift`
- `Dspeech/Core/Settings/PrivacySettings.swift`
- `Dspeech/Core/Translation/TranslationService.swift`
- `Dspeech/Core/Translation/TranslationServiceProtocol.swift`
- `Dspeech/Core/Translation/TranslationLanguagePackManager.swift`

Project-level:

- `Dspeech.xcodeproj/project.pbxproj` (Info.plist key declarations).

Docs:

- `docs/adr/0002-privacy-local-only-default.md` — anchor decision.
- `docs/product/launch-positioning.md` — marketing claim under audit.
- `docs/PLAN-2026-05-18.md` — current iteration plan.
- Repo-level `CLAUDE.md` hard rules 1, 2, 3 — privacy/no-fake-cloud/no-placeholders.
