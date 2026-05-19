# Apple Translation framework — iOS 26 API dossier

Frozen reference for every `Translation`-framework symbol the Dspeech Core
layer touches, the on-device guarantees the project relies on, and the
ADR-0002 compliance map for the F3 translation slice (PRD §1).

- Project deployment target: iOS 26.0 (`Dspeech.xcodeproj/project.pbxproj` →
  `IPHONEOS_DEPLOYMENT_TARGET = 26.0`). The Translation framework itself is
  iOS 18.0+, so no `@available` gate is required on this path.
- Verification source: Apple DocC JSON under
  `developer.apple.com/tutorials/data/documentation/translation/*.json`,
  re-fetched 2026-05-19 (the anti-hallucination "fetch current docs" branch
  of repo `CLAUDE.md`, used because the Context7 MCP is not mounted in this
  build env — same substitution recorded by W1 in `docs/handoff.md`).
- Cross-check against the iOS 26.4 SDK Swift compiler at `f6fb939` /
  `16dc4c7` (the two commits that corrected an earlier "throwing" note on
  `TranslationSession.init(installedSource:target:)`).
- Source scope: `grep -rIn` over `Dspeech/Core/Translation/` returns three
  files — `TranslationServiceProtocol.swift`, `TranslationService.swift`,
  `TranslationLanguagePackManager.swift`. The dossier covers their entire
  symbol surface and nothing else.

## 1. Symbol surface used in Core

| Symbol                                              | Used in (Core)                                                                 | Apple DocC anchor                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `LanguageAvailability`                              | `TranslationService.swift:51`, `TranslationLanguagePackManager.swift:72`       | `documentation/translation/languageavailability`                                 |
| `LanguageAvailability.init()`                       | same call sites (default init)                                                 | `documentation/translation/languageavailability` (default init, no parameters)   |
| `LanguageAvailability.status(from:to:)`             | `TranslationService.swift:51`, `TranslationLanguagePackManager.swift:72`       | `documentation/translation/languageavailability/status(from:to:)`                |
| `LanguageAvailability.Status` (`.installed`/`.supported`/`.unsupported`) | switched in both files                                          | `documentation/translation/languageavailability/status-swift.enum`               |
| `TranslationSession`                                | `TranslationService.swift:97`                                                  | `documentation/translation/translationsession`                                   |
| `TranslationSession.init(installedSource:target:)`  | `TranslationService.swift:97`                                                  | `documentation/translation/translationsession/init(installedsource:target:)`     |
| `TranslationSession.translate(_:)`                  | `TranslationService.swift:98`                                                  | `documentation/translation/translationsession/translate(_:)`                     |
| `TranslationSession.Response.targetText`            | `TranslationService.swift:99`                                                  | `documentation/translation/translationsession/response/targettext`               |
| `TranslationSession.prepareTranslation()`           | referenced only in DocC of `TranslationLanguagePackPreparer` (no direct call)  | `documentation/translation/translationsession/preparetranslation()`              |
| `TranslationSession.Configuration`                  | referenced in DocC of `TranslationPackSystemDownloadPort` (W5 SwiftUI seam)    | `documentation/translation/translationsession/configuration`                     |
| `TranslationError` (cases listed in §3)             | mapped in the single `do/catch` at `TranslationService.swift:96-117`            | `documentation/translation/translationerror`                                     |
| `View.translationTask(_:action:)` (SwiftUI modifier)| referenced in DocC of `TranslationPackSystemDownloadPort` (W5 SwiftUI seam)    | `documentation/translation/swiftui/view/translationtask(_:action:)`              |

The Core layer **never imports** `Translation` at the protocol level — only
the two adapter files (`AppleTranslationService`, `AppleTranslationLanguagePackManager`)
do (`TranslationService.swift:2`, `TranslationLanguagePackManager.swift:2`).

## 2. Per-symbol signatures, async/throws, on-device guarantees

### `LanguageAvailability` — `documentation/translation/languageavailability`

- `init()` — default, parameterless.
- `func status(from: Locale.Language, to: Locale.Language) async -> Status`
  (DocC `…/languageavailability/status(from:to:)`) — **async, non-throwing**.
  Languages are `Locale.Language`, never BCP-47 `String`.
- `enum Status: Sendable { case installed, supported, unsupported }`
  (DocC `…/languageavailability/status-swift.enum`).
  - `.installed` → on-device assets present, translation runs fully offline.
  - `.supported` → pair is supported but assets not installed yet; requires
    explicit user-initiated download via the SwiftUI system UI (see §4).
  - `.unsupported` → the engine cannot translate this pair, ever.
- On-device guarantee: the call is a local capability query; per Apple DocC
  it does not require network and does not present UI.

### `TranslationSession` — `documentation/translation/translationsession`

- `init(installedSource: Locale.Language, target: Locale.Language)` (DocC
  `…/translationsession/init(installedsource:target:)`) — **synchronous,
  non-throwing**, installed-only. The DocC declaration fragment carries no
  `throws`/`async` (re-verified 2026-05-19); confirmed by the iOS 26.4 SDK
  Swift compiler at `f6fb939`. Apple's earlier WWDC-era summary that called
  this "throwing" is **inaccurate** for the iOS 26 surface and is corrected
  in this dossier; using `try` here is a compile error on iOS 26.4.
- `func translate(_ string: String) async throws -> Response` (DocC
  `…/translationsession/translate(_:)`) — async, throwing. Errors surface as
  `TranslationError` (mapped at one boundary, §3).
- `struct Response { let targetText: String }` (DocC
  `…/translationsession/response/targettext`) — only `targetText` is read on
  the F3 path; no source-attribution or confidence fields are consumed.
- `func prepareTranslation() async throws` (DocC
  `…/translationsession/preparetranslation()`) — async, throwing. Per Apple
  DocC, this is the sole **programmatic** route that can acquire a not-yet-
  installed pair, and it is callable only from a `TranslationSession` minted
  by `.translationTask(_:action:)` (i.e. via `TranslationSession.Configuration`).
  It is **not** called from Core; it is delegated to the W5 SwiftUI seam
  (`TranslationPackSystemDownloadPort`, `TranslationLanguagePackManager.swift:28-42`).
- On-device guarantee: model execution happens on-device; the only network
  traffic is Apple's OS-level asset fetch, owned by the system, in the same
  class as the keyboard/dictation model fetch (ADR 0002 carve-out).

### `TranslationSession.Configuration` — `documentation/translation/translationsession/configuration`

- `init(source: Locale.Language? = nil, target: Locale.Language? = nil)`,
  `Equatable`. The `.translationTask(_:action:)` modifier observes this
  value and mints a fresh `TranslationSession` for the SwiftUI view that
  owns it. Used by the W5 SwiftUI seam to mint the session that
  `prepareTranslation()` runs on; not constructed from Core.

### `TranslationError` — `documentation/translation/translationerror`

A `struct` with `static let` cases plus `~=`, conforming to `Error` (DocC
`documentation/translation/translationerror`). Mapped 1:1 to
`TranslationServiceError` at the single boundary in
`AppleTranslationService.translate(_:from:into:)`
(`TranslationService.swift:96-117`):

| `TranslationError` static                       | `TranslationServiceError` case                                  |
| ----------------------------------------------- | --------------------------------------------------------------- |
| `.nothingToTranslate`                           | `.emptyInput`                                                   |
| `.notInstalled`                                 | `.languagePackNotInstalled(source:target:)`                     |
| `.unsupportedSourceLanguage`                    | `.sourceLanguageUnsupported(_)`                                 |
| `.unsupportedTargetLanguage`                    | `.targetLanguageUnsupported(_)`                                 |
| `.unsupportedLanguagePairing`                   | `.languagePairingUnsupported(source:target:)`                   |
| `.alreadyCancelled` / Swift `CancellationError` | `.sessionCancelled`                                             |
| any other framework error                       | `.engineFailure(String(describing:))` (single boundary log)     |

No case in `TranslationServiceError` represents a network or cloud
condition — none exists on the framework either.

## 3. Offline language pack lifecycle

States derive entirely from `LanguageAvailability.Status` (DocC
`…/languageavailability/status-swift.enum`):

1. **Absent / `.unsupported`** — `LanguageAvailability.status(from:to:)`
   returns `.unsupported`. Terminal: no acquisition route exists. Core
   surfaces `TranslationServiceError.languagePairingUnsupported(source:target:)`
   (`TranslationLanguagePackManager.swift:79`).
2. **Supported, not installed / `.supported`** — assets are not on disk yet.
   Apple exposes **no** programmatic silent downloader. The only public
   acquisition routes (DocC `…/translationsession/preparetranslation()` and
   the SwiftUI `…/swiftui/view/translationtask(_:action:)`) require a
   `TranslationSession` minted by `.translationTask(_:action:)`. Core
   delegates this to the W5 SwiftUI port
   (`TranslationLanguagePackManager.swift:28-42` and `:77`). Apple's system
   sheet shows download size and asks for user confirmation; user dismissal
   surfaces as `TranslationServiceError.sessionCancelled`.
3. **Installed / `.installed`** — `TranslationSession.init(installedSource:target:)`
   (DocC `…/translationsession/init(installedsource:target:)`) constructs a
   session synchronously; `translate(_:)` returns
   `Response.targetText`. The pre-flight availability check at
   `TranslationService.swift:87-94` ensures we never reach this constructor
   on a missing pair, so any future framework change to its error surface
   cannot leak into the deterministic protocol contract.
4. **Persistence** — Apple owns asset persistence; there is no DocC-exposed
   API to enumerate installed pairs by path, no purge API, and no eviction
   signal. The framework's only persistence-visible operation is the
   `.installed`/`.supported` transition observed via
   `LanguageAvailability.status(from:to:)`. The repo therefore does not
   cache pack state — every gate calls `status(from:to:)` afresh.
5. **Error modes** — see §2 `TranslationError` table; the only lifecycle-
   specific error is `.notInstalled` (mapped to `.languagePackNotInstalled`),
   which the Core path is engineered to make unreachable on the install
   route (pre-flight gate at `TranslationService.swift:87-94`).

## 4. ADR-0002 compliance map (zero off-device leak)

ADR 0002 hard rule: under `PrivacyMode.localOnly` no audio, transcript, or
metadata leaves the device. Mapped per call path:

| Path                                                                                                          | Network footprint                                                       | Verdict                  |
| ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------ |
| `LocalTranslationService.availability` → `AppleTranslationService.availability` → `LanguageAvailability.status(from:to:)` | Local capability query (DocC: no network requirement)        | ✅ on-device only         |
| `LocalTranslationService.translate` → `AppleTranslationService.translate` → `TranslationSession.init(installedSource:target:)` + `translate(_:)` | Model execution on-device (DocC `…/translationsession`)                | ✅ on-device only         |
| `TranslationLanguagePackManager.prepareLanguages` (`.installed` branch)                                       | No system call                                                          | ✅ on-device only         |
| `TranslationLanguagePackManager.prepareLanguages` (`.supported` branch) → `TranslationPackSystemDownloadPort.requestSystemDownload` → SwiftUI `.translationTask` + `prepareTranslation()` | Apple-owned OS asset fetch only (ADR 0002 carve-out, same class as keyboard/dictation model download) | ✅ ADR-0002 compliant     |
| `TranslationLanguagePackManager.prepareLanguages` (`.unsupported` branch)                                     | No system call (throws)                                                 | ✅ on-device only         |

Mechanical enforcement (PLAN W7, `docs/PLAN-2026-05-19.md:101`):
`grep -rIn "URLSession\|URLRequest\|HTTPSURL"` over
`Dspeech/Core/Translation/` must return 0. The Core files import only
`Foundation` and `Translation` (`TranslationService.swift:1-2`,
`TranslationLanguagePackManager.swift:1-2`,
`TranslationServiceProtocol.swift:1`); no networking type is reachable.

## 5. Surface gaps between iOS 17.4 (original ADR target) and iOS 26

The original PLAN row (`docs/PLAN-2026-05-19.md:28`) framed the API as
"iOS 17.4+ / 26 path". On the iOS 26 surface that this project actually
ships against:

- The Translation framework's public availability is **iOS 18.0+**, not
  iOS 17.4. iOS 17.4 surfaces existed in `_Translation` private/preview
  form during the SDK's beta window and are not part of the iOS 26 DocC
  contract. Core compiles at iOS 26.0 deployment target so the distinction
  is moot for shipping code, but the dossier records the correction so
  future ADR text does not propagate the "iOS 17.4" claim.
- `TranslationSession.init(installedSource:target:)` is **synchronous and
  non-throwing** on iOS 26 (verified above). Any older note (including the
  architecture doc at `docs/architecture-mvp-slice-2026-05-19.md:33` and
  earlier DocC text written for `…/preparetranslation()`'s call site)
  claiming it `throws` is **wrong** for iOS 26.4 and is superseded by this
  dossier.
- `prepareTranslation()` remains async and throwing and remains callable
  only from a session minted by `.translationTask(_:action:)` via
  `TranslationSession.Configuration` (DocC re-verified 2026-05-19). No
  iOS 26-only programmatic downloader has appeared.
- `LanguageAvailability.status(from:to:)` remains async, non-throwing, and
  returns the same three-case `Status` enum. No DocC delta on iOS 26.
- `TranslationError` remains a `struct` with `static let` cases and the
  `~=` operator (i.e. pattern-matched with `catch TranslationError.notInstalled`,
  not `catch let e as TranslationError where e == …`); the
  `do/catch` shape at `TranslationService.swift:96-117` matches.

UNKNOWN (not load-bearing for F3, recorded for honesty):
- Whether iOS 26 adds a public "list installed pairs" or "purge pair" API.
  DocC re-fetch 2026-05-19 shows none; the framework still hides
  persistence behind `LanguageAvailability.status`.
- Whether iOS 26 introduces an enumerated "downloading" or "pending"
  `Status` case beyond `.installed`/`.supported`/`.unsupported`. DocC
  re-fetch 2026-05-19 shows the same three cases; the `@unknown default`
  fallbacks at `TranslationService.swift:59` and
  `TranslationLanguagePackManager.swift:80` keep this safe regardless.

## 6. F3 deferral risk register

PLAN row "Fail-soft" (`docs/PLAN-2026-05-19.md:33`) requires this dossier
to record any condition that would force F3 out of the MVP gate. Result:
**no deferral**. Justification:

- All three symbols required by F3 (`LanguageAvailability.status(from:to:)`,
  `TranslationSession.init(installedSource:target:)`,
  `TranslationSession.translate(_:)`) exist on iOS 26.0 with the signatures
  and on-device guarantees the Core protocols depend on (§2).
- The one Apple-owned downloader (`prepareTranslation()` via
  `.translationTask`) has a system-presented UI; it is ADR-0002 compliant
  under the same carve-out as keyboard/dictation model downloads and is
  reachable from the explicit "Download pack" CTA only (PRD §1 line 33,
  PLAN architecture doc line 68-70).
- No call path in `Dspeech/Core/Translation/` reaches a networking type;
  the PLAN W7 grep is mechanically green by construction (§4).
- The deterministic protocol contract
  (`TranslationService`/`TranslationLanguagePackPreparer`) does not depend
  on any UNKNOWN listed in §5; the `@unknown default` arms and the
  pre-flight availability gate make those gaps non-load-bearing.

Trigger that would re-open ADR 0007 as a deferral:
1. A future DocC re-fetch shows `TranslationSession.translate(_:)` calling
   out network requirements on the `.installed` path, **or**
2. Apple removes `init(installedSource:target:)` from the iOS public
   surface (forcing all sessions through `.translationTask`, which would
   break the host-testable Core seam).

Until either fires, F3 ships against this dossier unchanged.
