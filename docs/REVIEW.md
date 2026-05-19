# W6 — Independent Reviewer Report (round 1)

- **status:** CHANGES_REQUESTED
- **date:** 2026-05-19
- **branch:** `feat/mvp-completion-2026-05-19`
- **HEAD:** `2998ed2` (`feat(app): integrate Translation + Audio source + First-Run into main UI`)
- **base:** `main`
- **reviewer:** ubuntu-vm `claude -p` skeptical persona — fresh ctx, did not participate in W1–W5
- **test command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
- **test result:** **TEST FAILED** — unit tests 132/132 passed, but XCUITest target executed 3 tests with 2 failures.

## Independent Context7-substitute re-verification of cited Apple APIs

Context7 MCP unmounted (same finding W1–W5 recorded). I re-fetched the Apple DocC JSON (`developer.apple.com/tutorials/data/documentation/translation/...index.json`) myself in this review session — not relying on implementer-cited signatures:

| Symbol | Cited by | Independent re-verification |
|---|---|---|
| `TranslationSession.init(installedSource:target:)` | `TranslationService.swift:97`, `TranslationLanguagePackManager.swift` | `convenience init(installedSource: Locale.Language, target: Locale.Language?)` — **non-throwing, synchronous** ✅ matches the `f6fb939` correction |
| `LanguageAvailability.status(from:to:)` | `TranslationService.swift:51` | `func status(from: Locale.Language, to: Locale.Language?) async -> LanguageAvailability.Status` — **async, non-throwing** ✅ |
| `TranslationSession.translate(_:)` (String) | `TranslationService.swift:98` | `func translate(String) async throws -> TranslationSession.Response` ✅ (overload `translate(_:)-4m20l`) |
| `TranslationSession.prepareTranslation()` | `SettingsSheet.swift:80` | `func prepareTranslation() async throws` ✅ |
| `LanguageAvailability.Status` cases | `TranslationService.swift:53-58` | `.installed / .supported / .unsupported` ✅ |
| `TranslationError.*` cases | `TranslationService.swift:100-115` | All six cited cases present in DocC ✅ |
| `AVAudioSession.availableInputs` / `setPreferredInput(_:)` / `currentRoute` / `routeChangeNotification` / `RouteChangeReason` | `AudioInputService.swift` | DocC matches; project also has identical green usage at `AppleSpeechLiveTranscriptionEngine.swift` |

**Verdict:** zero hallucinated APIs. The corrective commit `f6fb939` ("drop superfluous try on non-throwing TranslationSession init") and the documentation correction `16dc4c7` were necessary and are now correct.

## Findings

### 🔴 BLOCK-1 — XCUITest regression: `settings-button` becomes unhittable after integration

**Evidence (`/tmp/dspeech-review-full.log`):**

```
Test Case '-[DspeechUITests.DspeechUITests testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn]'
    t = 4.36s Find the "privacy-badge" StaticText                  ← OK
    t = 4.37s Tap "settings-button" Button
    t = 4.41s     Scroll element to visible
    t = 4.42s     Computed hit point {-1, -1} after scrolling to visible
    t = 4.82s Waiting 4.0s for "cloud-toggle" Switch to exist
    t = 8.86s     XCTAssertTrue failed                              ← FAIL
```

The settings-button exists in the accessibility tree (test 1 `testAppLaunchesToTranscriptSurface` asserts its `.exists` and PASSES at t=4.40s) but `Computed hit point {-1, -1}` means XCUITest could not compute an on-screen tappable rectangle, so the tap never reaches the button and `.sheet(isPresented: $showSettings)` never fires. Both `testSettingsButtonOpensSettingsSheet` and `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` regress on the identical symptom. `testAppLaunchesToTranscriptSurface` only checks `.exists` and so does not surface the same fault.

**Suspected cause (for implementer to investigate, not me to fix):**

- `Dspeech/App/ContentView.swift:229-251` `settingsButton(isLandscape:)` uses `Button { ... } label: { Image ... }` + `.buttonStyle(.plain)` + `.contentShape(Circle())`. The `.contentShape(Circle())` is applied *after* `.buttonStyle(.plain)`, which on iOS 26 SwiftUI can shrink the hit-target to a zero-radius circle when the SwiftUI layout system measures the `Image` before the `.frame(width:height:)` modifier inside the label propagates. Recommended: remove `.contentShape(Circle())` or move the `.frame(...)` outside the label, or use `Button("…", systemImage:)` form.
- Alternative hypothesis: HStack overflow in the control bar in portrait (line 204-227). Total content (`Dspeech` title + privacy badge + Spacer + settings circle + `Toggle` with `.fixedSize()`) is right at the edge of iPhone 17 Pro's 393 pt; if any element layout-rounds beyond the bound the settings-button's frame can clip to the right edge and produce a negative hit centre.

Either way, this **blocks W7 (verifier gate)**: the W7 contract requires `xcodebuild build test` to exit zero. It currently exits non-zero with the `** TEST FAILED **` banner.

### 🔴 BLOCK-2 — W4b deliverables claimed but absent from the codebase

`docs/handoff.md` "W4b firstrun tester" block claims three files:

- `DspeechTests/FirstRunCoordinatorTests.swift` (9 @Test cases, claimed in section "tests_authored")
- `DspeechUITests/FirstRunFlowUITests.swift` (3 XCUITests)
- `DspeechUITests/AboutViewUITests.swift` (2 XCUITests)

I verified by `Glob` and `git log --all --diff-filter=A -- <path>`:

```
DspeechTests/*.swift        → no FirstRunCoordinatorTests.swift
DspeechUITests/*.swift      → only DspeechUITests.swift; no FirstRun/About files
git log --diff-filter=A     → none of the three paths ever added on any branch
```

W5 handoff openly acknowledges this and notes the pbxproj refs were *removed* because the files were never committed. Consequences:

1. `DefaultFirstRunCoordinator` (the state machine) has **zero** unit-test coverage — the rule "tests are specifications, not metrics" (repo `CLAUDE.md`, `@common/testing.md`) is violated for a brand-new, branch-introduced Sendable class with thread-safe state, persistence semantics, and a fail-safe re-show contract.
2. `FirstRunView` (3-card walk, skip path, language-picker on last card) has **zero** UI smoke coverage. The first-run flow is the user's literal first interaction; it cannot ship un-smoke-tested.
3. `AboutView` (PRD §2 attributions, privacy badge in Settings detail, license copy) has **zero** UI coverage. Hard rule 4 ("Privacy mode visible at all times") extends into About per the `about-privacy-badge` identifier the handoff defines, but no test asserts the badge is actually rendered there.

This is not a "missing nice-to-have" — it's three branch-resident deliverables advertised as done and audited as absent.

### 🟡 MAJOR-3 — Apple-edge mapping in `AppleTranslationService` / `AppleTranslationLanguagePackManager` is wholly untested

The "functional core, imperative shell" split is correct in principle, and `LocalTranslationService` + `TranslationLanguagePackManager` are well-tested via the fake backend (24 @Test, all PASS). However:

- `AppleTranslationService.translate(_:from:into:)` (`TranslationService.swift:79-117`) contains the entire Apple `TranslationError` → `TranslationServiceError` mapping table — `.notInstalled` → `.languagePackNotInstalled`, `.unsupportedSourceLanguage` → `.sourceLanguageUnsupported`, `.alreadyCancelled` / `CancellationError` → `.sessionCancelled`, `.nothingToTranslate` → `.emptyInput`, internal/unknown → `.engineFailure(String(describing:))`.
- `AppleTranslationLanguagePackManager.prepareLanguages(from:into:)` (`TranslationLanguagePackManager.swift:68-83`) maps `LanguageAvailability.Status` → success/delegate/unsupported.
- `TranslationPackDownloadCoordinator` (`SettingsSheet.swift:121-178`) maps `.translationTask` outcomes onto the same typed enum.

The W2b handoff explicitly flags these as `coverage_gaps (honest)` and defers them to W7/W10 device verification — but `docs/PLAN-2026-05-19.md` lists W7 as a code/build/grep gate, not a device-MT run, and W10 is the Andrei hand-off, not a verification step. So the Apple-edge error mapping ships with no host-test, no device-test, no integration-test of any kind — only a hand-typed catch table. For a slice that ships F3 to the MVP gate this is a real risk: a wrong/dropped case here silently routes a translation error to `.engineFailure(String(describing:))`, hiding the actual semantics from the UI.

**Suggested fix:** introduce a thin `TranslationSessionPort` seam analogous to `AudioInputSessionPort` (PR-able by W1 architect), and write decorator tests for the Apple→domain mapping table. At minimum, document the un-tested cases in `docs/architecture-mvp-slice-2026-05-19.md` "Known device-only gates" and add a `xfail`/device-only integration test scheduled for W10.

### 🟡 MAJOR-4 — `DspeechApp.applyFirstRunLaunchOverride()` couples UI-test launch wiring into production composition root

`Dspeech/App/DspeechApp.swift:33-50` runs unconditionally on every app launch and contains a "production passes none of these branches" branch sniff:

```swift
} else if arguments.contains(where: { $0.hasPrefix("-dspeech.") }) {
    defaults.set(true, forKey: storeKey)
}
```

The only thing keeping this from firing in production is the implicit assumption that no production launcher ever passes a `-dspeech.*` argument. That's a runtime invariant a future change (deep-link argument, App Clip, MDM-provisioned launch arg, debugger CLI override) can violate accidentally — and the failure mode is silent: a user's first launch skips onboarding entirely with no log.

Repo `CLAUDE.md` rule 3 ("No placeholders pretending functionality") and `@common/coding-style.md` ("No hidden globals, no ambient context") argue for moving this branch behind an explicit `#if DEBUG` / `DSPEECH_UITEST=1` env-var gate (the `DSPEECH_UITEST` already drives `UITestOnboardingPermissionRequester`, so the gate exists). The non-blocking-but-quietly-skipping arg-prefix sniff should not live in the release composition root.

### 🟡 MAJOR-5 — `LocalTranslationService.translate(_:)` silently forwards the untrimmed `text` even though the empty-input guard runs on the trimmed copy

`Dspeech/Core/Translation/TranslationService.swift:158-166`:

```swift
let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { throw .emptyInput }
return try await backend.translate(text, from: source, into: target)  // ← original text
```

The DocC contract on the protocol (`TranslationServiceProtocol.swift:29-30`) is "*The input was empty or whitespace-only (`TranslationError.nothingToTranslate`)*". The Apple shell `AppleTranslationService.translate` *also* defends on a trimmed copy and then forwards `trimmed` (line 84-85, 98). The decorator forwarding `text` (untrimmed) is *not* symmetric to the inner Apple call. The visible effect is small (Apple will still translate `"  hello  "` happily) but the two branches of the contract now disagree about what the backend sees. Either:

- Document that the decorator's job is only to reject `emptyInput` *upstream* and that Apple sees raw text including whitespace, or
- Forward `trimmed` to keep the two layers symmetric (`AppleTranslationService` itself trims, so this would be a no-op there but match `FakeTranslationBackend.recordedInputs` to user-visible content).

This is also a test-quality issue: `TranslationServiceTests.should_translate_very_long_input_without_truncation_when_pair_installed()` (`TranslationServiceTests.swift:176-190`) explicitly asserts the *original* untrimmed length is preserved, which means the chosen semantic ("forward untrimmed") is locked in by tests but never documented on the protocol DocC. Pick one and document it.

### 🟢 MINOR-6 — `try?` audit

Two `try?` in the new code; neither is a silent-failure smell:

- `AudioInputService.swift:92` — `try? await Task.sleep(for: duration)` inside the default debounce sleep closure. `Task.sleep` only throws `CancellationError` on `Task.cancel()`, which is the *intended* exit path of the debounce pump. Acceptable.
- Pre-existing `AppleSpeechLiveTranscriptionEngine.swift:156` `try? AVAudioSession.sharedInstance().setActive(false, ...)` — out of scope for this branch but flagged as a known smell.

### 🟢 MINOR-7 — `AudioRouteTests` debounce/coalesce tests run on the real wall clock

`AudioRouteTests.contractDebouncesRapidRouteChangesAndKeepsTheLatest` and the analogous `observerRoutesDebouncesARapidPlugPullBurstToTheLatestRoute` pass `routeDebounce: .milliseconds(120)` and then `Task.sleep(nanoseconds: 250_000_000)`. The production code accepts an injected `sleep:` closure precisely so this can be deterministic — but the tests use the real timer. They PASS locally, but on a heavily loaded CI box (or a parallel `xcodebuild -parallel-testing-enabled YES` run) a 250 ms slack against a 120 ms debounce is thin. Recommend wiring the injected `sleep` to an instant-resume closure in those two specs.

### 🟢 MINOR-8 — `SettingsSheet` recreates `packPreparer` chain on every body recomputation

`Dspeech/App/SettingsSheet.swift:17-25` keeps `packCoordinator` as `@State` (correct — preserved across recomputes) but `packPreparer` is a `private var` computed property that allocates `TranslationLanguagePackManager(backend: AppleTranslationLanguagePackManager(systemDownloadPort: SwiftUITranslationPackDownloadPort(coordinator: …)))` every body call. The chain is stateless (all are `struct` over a `@MainActor` class), so this is harmless — but each `TranslationSettingsSection` `let preparer: any TranslationLanguagePackPreparer` re-binds on every parent body refresh, which can interrupt an in-flight `.task(id:)`. Cheap fix: hoist `packPreparer` to a `@State`-backed lazy var or a `let` computed once in `init`.

### 🟢 MINOR-9 — Mutation-test sample: kind mapping

I mutation-tested `AppleAudioInputService.kind(forPortType:)` (`AudioInputService.swift:185-200`) mentally by reading `AudioInputServiceTests.adapterMapsPortTypeRawValueToTheCorrectPickerKind` (line 237-252). If the implementer flipped `usbAudio` and `bluetoothHFP` branches, the parameterized test would catch it — `(usbSnapshot, .wired)` and `(bluetoothSnapshot, .bluetooth)` are both asserted. Mutation surface looks adequately covered.

I did *not* mutation-test the SwiftUI View bodies because they have no test coverage — that's findings BLOCK-2 and MAJOR-3.

## Anti-AI-failure pattern audit (mechanical)

| Check | Result |
|---|---|
| `grep -rn "TODO\|FIXME\|fatalError\|Coming soon\|unimplemented"` over `Dspeech/` | **0** matches |
| `grep -rn "URLSession\|URLRequest\|HTTPSURL\|HTTPURLResponse"` over `Dspeech/` | **0** matches (ADR 0002 holds) |
| `grep -rn "try?"` over new files in `Dspeech/Core` | 1 (see MINOR-6, justified) |
| `grep -rn "catch\s*\{\s*\}"` over `Dspeech/` | **0** matches |
| Typed throws on every new error boundary | ✅ (TranslationServiceError, AudioInputServiceError, FirstRunCoordinatorError) |
| `accessibilityIdentifier(...)` on every new control surfaced by tests | ✅ (the existing UI tests reference exactly the identifiers shipped; what's missing is the *tests*, not the identifiers — see BLOCK-2) |
| DocC on every public type/protocol/symbol in new Core files | ✅ |
| `@MainActor` only where main-actor isolation is genuinely needed | ✅ (`FirstRunViewModel`, `TranslationPackDownloadCoordinator`; rest is `Sendable` non-isolated) |
| Hallucinated Apple APIs | **0** (re-verified against Apple DocC JSON in this review session) |

## Cycle status

- Round 1 of (max) 3.
- This is the first reviewer pass on this branch. No previous reviewer findings to compare for echo-fix detection.

## Required for APPROVED

1. Resolve **BLOCK-1**: `DspeechUITests` `testSettingsButtonOpensSettingsSheet` and `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` must pass. Root-cause the `Computed hit point {-1, -1}` on `settings-button`; do not "fix" by deleting/relaxing the assertions.
2. Resolve **BLOCK-2**: either (a) commit the three claimed W4b test files with the contracts described in `docs/handoff.md` W4b block, or (b) re-route the wave so a different test suite covers `DefaultFirstRunCoordinator`, `FirstRunView` smoke, and `AboutView` smoke (e.g. `FirstRunCoordinatorTests` plus extending `DspeechUITests.swift` with first-run/about cases).
3. Address **MAJOR-3, MAJOR-4, MAJOR-5** or document them as accepted-risks via short PRs / ADR amendments. MAJOR-3 in particular leaves F3 effectively untested at the Apple edge.

MINOR-6/7/8/9 are non-blocking suggestions for the next round.
