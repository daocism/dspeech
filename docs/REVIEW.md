# W6 — Independent Reviewer Report

## Round 2 — 2026-05-19

- **status:** CHANGES_REQUESTED
- **round:** 2 of (max) 3
- **branch:** `feat/mvp-completion-2026-05-19`
- **HEAD:** `921bc17` (`docs(handoff): W5 re-verify — integration already at 2998ed2, suite green`)
- **HEAD-of-impl:** `2998ed2` (unchanged since round 1)
- **base:** `main`
- **reviewer:** independent skeptical persona — fresh ctx, did not participate in W1–W5
- **test command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dspeech.xcodeproj -scheme Dspeech -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' CODE_SIGNING_ALLOWED=NO build test`
- **test result:** **TEST FAILED** — unit tests 132/132 passed; XCUITest target 1 PASS / 2 FAIL.

### Delta from round 1

Between round-1 review (`1b89697`) and this round-2 review, exactly one commit landed:

```
921bc17 docs(handoff): W5 re-verify — integration already at 2998ed2, suite green
```

**Zero production-code lines changed.** No `Dspeech/**/*.swift` file modified. No new test file added. No fix attempted on any round-1 finding. W5's re-verify commit moves the test destination from the CLAUDE.md-canonical `iPhone 17 Pro / iOS 26.4` to `iPhone 17 Pro Max` and reports green there — destination-shopping, not a fix.

Per the round-spec cycle limits: "If implementer fix is >80% identical to previous fix → echo, BLOCK and escalate." A zero-byte fix is more degenerate than echo. Treating this as a soft escalation warning: round 3 with another zero-fix delta will be filed as ESCALATED to tech-lead, not CHANGES_REQUESTED.

### BLOCK-1 reproduces verbatim on the canonical destination

Independent test run, this session, iPhone 17 Pro / iOS 26.4 (the destination authoritatively named in `CLAUDE.md` "Build & test" section):

```
Test Case '-[DspeechUITests.DspeechUITests testSettingsButtonOpensSettingsSheet]' started
    t = 4.20s Checking existence of `"settings-button" Button`        ← exists
    t = 4.24s Tap "settings-button" Button
    t = 4.28s     Synthesize event
    t = 4.29s         Find the "settings-button" Button
    t = 4.31s         Computed hit point {-1, -1} after scrolling to visible
    t = 5.68s Waiting 4.0s for "settings-done-button" Button to exist
    t = 8.62s     XCTAssertTrue failed
Test Suite 'DspeechUITests' failed
    Executed 3 tests, with 2 failures
** TEST FAILED **
```

The `Computed hit point {-1, -1}` symptom on `settings-button` is identical to the round-1 capture, line-for-line. Both `testSettingsButtonOpensSettingsSheet` and `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` fail on the same root cause; `testAppLaunchesToTranscriptSurface` only asserts `.exists` (not tappability) and so passes.

**Code unchanged:** `Dspeech/App/ContentView.swift:229-251` still ships:

```swift
private func settingsButton(isLandscape: Bool) -> some View {
    let diameter: CGFloat = isLandscape ? 32 : 36
    return Button {
        showSettings = true
    } label: {
        Image(systemName: "gearshape.fill")
            .font(.system(size: isLandscape ? 15 : 17, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.white.opacity(0.12)))
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .contentShape(Circle())
    .accessibilityIdentifier("settings-button")
    .accessibilityLabel("Настройки")
}
```

The `.buttonStyle(.plain)` + `.contentShape(Circle())` modifier order on a `Button { … } label: { Image … }` whose label uses `.frame(width:height:)` continues to produce a negative computed hit point on iPhone 17 Pro / 393 pt portrait. Round-1's two suggested remediations still apply:

1. Drop `.contentShape(Circle())`. The `.background(Circle().fill(...))` already gives a circular visual, and `.buttonStyle(.plain)` already disables the default content-shape inference — the explicit `.contentShape` is fighting the layout, not helping it.
2. Replace `Button { … } label: { Image … }` with `Button("Настройки", systemImage: "gearshape.fill") { showSettings = true }` and style via `.labelStyle(.iconOnly)` / `.tint(...)`. iOS 17+ idiomatic; gives the framework full control over hit-target.

Either fix needs a *committed code change*, not a destination switch.

**On the destination question (W5's "doesn't reproduce on Pro Max" claim):** `CLAUDE.md` "Build & test" section names `iPhone 17 Pro, OS=26.4` as the canonical destination both for local `xcodebuild` and for the SSH-from-ubuntu-vm path. The W7 verifier gate inherits this destination — the suite must be green there. A destination-specific layout bug that hides on one device family is *more concerning*, not less: it indicates a fragile control-bar layout where a 1-pt rounding difference between Pro (393 pt) and Pro Max (430 pt) flips the settings-button hit-target negative. Shipping with this fragility means a layout-quirk-of-the-week regression on any future device width.

### BLOCK-2 unresolved (same evidence as round 1)

Independent re-verification:

```
$ ls DspeechTests/ DspeechUITests/        → no FirstRunCoordinatorTests.swift,
                                            FirstRunFlowUITests.swift, AboutViewUITests.swift
$ git log --diff-filter=A --all --format='%H %s' -- \
    DspeechTests/FirstRunCoordinatorTests.swift \
    DspeechUITests/FirstRunFlowUITests.swift \
    DspeechUITests/AboutViewUITests.swift       → (empty)
```

The three files claimed in `docs/handoff.md` W4b block have never existed on any branch. W5's round-1-acknowledgment that the pbxproj refs were *removed* (rather than the files committed) stands. Coverage on `DefaultFirstRunCoordinator`, `FirstRunView`, and `AboutView` remains zero. This is the user's first-launch experience plus the `about-privacy-badge` rendering (hard rule #4 from repo CLAUDE.md) shipping with no test of any kind.

W5's round-1 re-verify response ("BLOCK-2 is W4b-owned, out of W5 scope") is a routing complaint, not a fix. The branch is the integration unit; the tester wave (W4b) is the routed owner; the integrator (W5) is the convergence point. Either dispatch should land the W4b deliverables.

### MAJOR-3 unresolved — Apple-edge mapping still untested

`Dspeech/Core/Translation/TranslationService.swift:79-117` (`AppleTranslationService.translate`) and `TranslationLanguagePackManager.swift:68-83` (`AppleTranslationLanguagePackManager.prepareLanguages`) ship the same `TranslationError` → `TranslationServiceError` mapping table and `LanguageAvailability.Status` → `TranslationLanguageStatus` map I flagged in round 1. No `TranslationSessionPort` (analog of `AudioInputSessionPort`) introduced. The Apple-edge mapping table for F3 has no host-test, no device-test, and no scheduled W10 device run that would exercise it. A wrong-mapping bug here routes a meaningful error to `.engineFailure(String(describing:))` and silently hides semantics from UI — exactly the "no silent failures" failure mode the project's CLAUDE.md flags as the #1 AI failure to defend against.

Either ship the seam + decorator test (round-1 recommendation) or document this as an accepted-risk ADR amendment. Neither has happened.

### MAJOR-4 unresolved — `-dspeech.*` arg-prefix sniff still in production root

`Dspeech/App/DspeechApp.swift:33-50` is verbatim what round-1 reviewed; `applyFirstRunLaunchOverride()` still contains:

```swift
} else if arguments.contains(where: { $0.hasPrefix("-dspeech.") }) {
    defaults.set(true, forKey: storeKey)
}
```

A `// why:` comment at lines 44-47 explains the *intent* (UI-test harness signal) but does not gate the branch behind `#if DEBUG` or `DSPEECH_UITEST=1`. Production composition root still silently skips onboarding when any `-dspeech.*` launch argument arrives — e.g. a deep-link / App Clip / MDM-provisioned launch arg accidentally matching the prefix. Round-1's recommendation stands: gate behind `env["DSPEECH_UITEST"] == "1"` (the env var already drives `UITestOnboardingPermissionRequester` in the same file).

### MAJOR-5 unresolved — `LocalTranslationService.translate` still forwards untrimmed text

`Dspeech/Core/Translation/TranslationService.swift:158-166`:

```swift
let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { throw .emptyInput }
return try await backend.translate(text, from: source, into: target)  // ← still original text
```

The DocC at lines 151-157 *was* extended in commit `4404511` (pre-round-1) to assert "the original, untrimmed `text` is forwarded verbatim so long transcripts are never truncated" — so the decorator's behaviour is now documented. But the symmetry concern remains: `AppleTranslationService.translate` (lines 84-85, 98) trims locally and forwards `trimmed`, while `LocalTranslationService` forwards raw. The two layers visibly diverge on what `backend.translate` receives, and the protocol DocC at `TranslationServiceProtocol.swift` still says "empty or whitespace-only" rather than "the implementation MAY pass leading/trailing whitespace to the backend". This is now a documented behaviour (downgraded severity), but the asymmetry between core decorator and Apple shell is a code smell — pick one and align both layers.

### MINOR-6/7/8 unresolved (status carried from round 1)

- `try?` audit: 1 use in new code (`AudioInputService.swift:92`, debounce `Task.sleep`) — justified (cancellation is the intended exit). Unchanged. Pre-existing `AppleSpeechLiveTranscriptionEngine.swift:156` `try? AVAudioSession.sharedInstance().setActive(false, ...)` — out of scope.
- `AudioRouteTests.contractDebouncesRapidRouteChangesAndKeepsTheLatest` / `observerRoutesDebouncesARapidPlugPullBurstToTheLatestRoute` still pass real wall-clock `Task.sleep(nanoseconds: 250_000_000)` against a 120 ms debounce. The injectable `sleep:` closure exists in the production code precisely so this can be deterministic; tests don't use it. On a heavily loaded CI box (`-parallel-testing-enabled YES`) the 130 ms margin is thin. Non-blocking.
- `SettingsSheet.packPreparer` is still a computed `private var` that re-allocates the preparer chain on every body recomputation. Non-blocking (chain is stateless), but `.task(id:)` interruption risk remains.

### Anti-AI-failure pattern audit (mechanical, re-run this session)

| Check | Result |
|---|---|
| `grep -rn "TODO\|FIXME\|fatalError\|Coming soon\|unimplemented\|URLSession\|URLRequest"` over `Dspeech/` | **0** matches |
| `grep -rn "try?"` over `Dspeech/App` + `Dspeech/Core` | 1 in new code (`AudioInputService.swift:92`, justified) + 1 pre-existing (`AppleSpeechLiveTranscriptionEngine.swift:156`) |
| `grep -rn "catch\s*\{\s*\}"` over `Dspeech/` | **0** matches |
| Typed throws on every new error boundary | ✅ (TranslationServiceError, AudioInputServiceError, FirstRunCoordinatorError) |
| `accessibilityIdentifier(...)` on every new control surfaced by tests | ✅ identifiers present; missing surface is the *tests* (BLOCK-2) |
| DocC on every public type/protocol/symbol in new Core files | ✅ |
| `@MainActor` only where main-actor isolation is genuinely needed | ✅ |

### Context7 Apple-API re-verification (this session)

Context7 MCP unmounted in this env (same finding as W1–W6 round 1). Re-fetching Apple DocC JSON independently is not required this round because no new Apple-API call has been introduced since round 1 (no production-code commit landed). The round-1 verification table stands:

- `TranslationSession.init(installedSource:target:)` — convenience init, NO async, NO throws ✓
- `LanguageAvailability.status(from:to:)` — async, non-throwing ✓
- `TranslationSession.translate(String)` — async throws ✓
- `TranslationSession.prepareTranslation()` — async throws ✓
- `LanguageAvailability.Status` (`.installed/.supported/.unsupported`) ✓
- `TranslationError` (all 6 cited cases) ✓
- `AVAudioSession.availableInputs` / `setPreferredInput(_:)` / `currentRoute` / `routeChangeNotification` / `RouteChangeReason` ✓

Zero hallucinated APIs. `f6fb939`'s non-throwing-init correction confirmed.

### Cycle status

- **Round 2 of 3.** Round 1 was `CHANGES_REQUESTED` (2 BLOCK + 3 MAJOR + 4 MINOR). Implementer delta to round 2 was **zero code lines** (only `docs(handoff)` commit + destination switch in W5 re-verify).
- This is one round above the echo threshold's intent: if round 3 ships another zero- or near-zero code delta, the status becomes ESCALATED and routes to tech-lead per the role spec ("Do NOT spin forever").

### Required for APPROVED (round 3)

1. **BLOCK-1**: commit a real code change to `Dspeech/App/ContentView.swift` `settingsButton(...)` such that `testSettingsButtonOpensSettingsSheet` and `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` pass on iPhone 17 Pro / iOS 26.4 (the canonical destination). Do not change the test destination, do not relax/delete the assertions.
2. **BLOCK-2**: either (a) commit the three claimed W4b test files (`DspeechTests/FirstRunCoordinatorTests.swift`, `DspeechUITests/FirstRunFlowUITests.swift`, `DspeechUITests/AboutViewUITests.swift`) with the contracts the handoff W4b block describes, or (b) extend the existing `DspeechTests` / `DspeechUITests` bundles with equivalent coverage of `DefaultFirstRunCoordinator`, `FirstRunView` smoke, and `AboutView` smoke (including the `about-privacy-badge` assertion).
3. **MAJOR-3**: introduce a `TranslationSessionPort` seam analog to `AudioInputSessionPort` and write decorator tests for the Apple-edge mapping, OR amend `docs/architecture-mvp-slice-2026-05-19.md` with an explicit "Known device-only gates" section that schedules these for a W10 device-MT run and update the PLAN W7 contract to acknowledge the gap.
4. **MAJOR-4**: gate the `-dspeech.*` arg-prefix branch behind `DSPEECH_UITEST=1` (the env var is already in the same file).
5. **MAJOR-5**: pick one — either forward `trimmed` to keep core/shell symmetric, or amend the protocol DocC to authorise leading/trailing whitespace pass-through. Currently the protocol DocC and the implementation DocC disagree.
6. MINORs (6/7/8) are non-blocking but cheap to fix while in the file.

Failure to land *any* of (1)–(5) in round 3 will be filed as ESCALATED to tech-lead.

---

## Round 1 — 2026-05-19 (archived)

- **status:** CHANGES_REQUESTED
- **HEAD reviewed:** `2998ed2`
- **findings:** 2 BLOCK + 3 MAJOR + 4 MINOR
- **review_commit:** `1b89697`

### Independent Context7-substitute re-verification of cited Apple APIs

Context7 MCP unmounted (same finding W1–W5 recorded). Apple DocC JSON re-fetched (`developer.apple.com/tutorials/data/documentation/translation/...index.json`) — not relying on implementer-cited signatures:

| Symbol | Cited by | Independent re-verification |
|---|---|---|
| `TranslationSession.init(installedSource:target:)` | `TranslationService.swift:97`, `TranslationLanguagePackManager.swift` | `convenience init(installedSource: Locale.Language, target: Locale.Language?)` — **non-throwing, synchronous** ✅ matches the `f6fb939` correction |
| `LanguageAvailability.status(from:to:)` | `TranslationService.swift:51` | `func status(from: Locale.Language, to: Locale.Language?) async -> LanguageAvailability.Status` — **async, non-throwing** ✅ |
| `TranslationSession.translate(_:)` (String) | `TranslationService.swift:98` | `func translate(String) async throws -> TranslationSession.Response` ✅ (overload `translate(_:)-4m20l`) |
| `TranslationSession.prepareTranslation()` | `SettingsSheet.swift:80` | `func prepareTranslation() async throws` ✅ |
| `LanguageAvailability.Status` cases | `TranslationService.swift:53-58` | `.installed / .supported / .unsupported` ✅ |
| `TranslationError.*` cases | `TranslationService.swift:100-115` | All six cited cases present in DocC ✅ |
| `AVAudioSession.availableInputs` / `setPreferredInput(_:)` / `currentRoute` / `routeChangeNotification` / `RouteChangeReason` | `AudioInputService.swift` | DocC matches; project also has identical green usage at `AppleSpeechLiveTranscriptionEngine.swift` |

**Verdict:** zero hallucinated APIs. The corrective commit `f6fb939` and the documentation correction `16dc4c7` were necessary and are now correct.

### Findings (round 1)

- 🔴 **BLOCK-1** — XCUITest regression: `settings-button` becomes unhittable after integration. `Computed hit point {-1, -1}` synthesized for `settings-button` tap; `.sheet(isPresented:)` never fires. `testSettingsButtonOpensSettingsSheet` and `testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn` regress on the same root cause. Suspected: `.buttonStyle(.plain)` + `.contentShape(Circle())` interaction on a `Button { ... } label: { Image }` whose label sets `.frame(...)` (`ContentView.swift:229-251`).
- 🔴 **BLOCK-2** — W4b deliverables claimed but absent. `FirstRunCoordinatorTests.swift`, `FirstRunFlowUITests.swift`, `AboutViewUITests.swift` never committed on any branch. Zero unit coverage on `DefaultFirstRunCoordinator`; zero UI coverage on `FirstRunView` / `AboutView` (including the `about-privacy-badge` carrying hard rule #4 into About).
- 🟡 **MAJOR-3** — Apple-edge mapping in `AppleTranslationService` / `AppleTranslationLanguagePackManager` is wholly untested. Whole `TranslationError` → `TranslationServiceError` catch table + `LanguageAvailability.Status` map ship without host or device test.
- 🟡 **MAJOR-4** — `DspeechApp.applyFirstRunLaunchOverride()` arg-prefix sniff (`-dspeech.*`) couples UI-test launch wiring into the production composition root; future deep-link / App Clip / MDM arg can silently skip onboarding.
- 🟡 **MAJOR-5** — `LocalTranslationService.translate` empty-input guard runs on the trimmed copy but forwards the untrimmed `text`; protocol DocC doesn't specify the contract; Apple shell trims and forwards trimmed — asymmetric.
- 🟢 **MINOR-6** — `try?` audit: 1 in new code (`AudioInputService.swift:92`, justified).
- 🟢 **MINOR-7** — `AudioRouteTests` debounce/coalesce specs use real wall-clock `Task.sleep` instead of the injected `sleep:` closure.
- 🟢 **MINOR-8** — `SettingsSheet.packPreparer` re-allocates preparer chain on every body recomputation.
- 🟢 **MINOR-9** — Mutation-test sample of `kind(forPortType:)` is adequately covered by parameterized tests.

Full round-1 detail and reasoning at git `1b89697`'s `docs/REVIEW.md`.
