import XCTest

/// Surface-level coverage of the first-run cover and the LOCAL privacy badge
/// that ADR 0002 (hard rule #4) requires to remain visible on the main control
/// bar after onboarding finishes.
///
/// Determinism strategy — the simulator's `UserDefaults` persists across
/// XCUIApplication launches, so every test must seed the
/// `hasCompletedFirstRun` flag explicitly rather than relying on the previous
/// test's residue. Two seeds are used:
///
///   - **Fresh install**: `DSPEECH_FORCE_FIRST_RUN=1` env wins over any
///     persisted value in `DspeechApp.applyFirstRunLaunchOverride()`.
///   - **Already completed**: `-hasCompletedFirstRun YES` arg-domain key wins
///     over any persisted value via `defaults.object(...)`.
///
/// Real OS permission alerts are bypassed via `DSPEECH_UITEST=1` so the test
/// never blocks on a system-permission sheet (repo `CLAUDE.md` rule 2: no
/// fake surface ships, the bypass is composition-root test wiring only).
///
/// Element-kind tolerance — SwiftUI projects `Button { } label: { Text }`
/// + `.buttonStyle(.plain)` as a generic accessibility element under
/// `app.descendants(matching: .any)`, not under `app.buttons[id]`. The
/// helpers below query both kinds so a future style tweak does not break the
/// suite for the wrong reason.
final class FirstRunFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstRunCoverPresentsReceiveOnlyCardOnFreshLaunch() {
        let app = launchFreshFirstRun()

        let cover = app.otherElements["first-run-view"]
        XCTAssertTrue(cover.waitForExistence(timeout: 8),
                      "first-run cover must present on a fresh install")

        let continueButton = anyElement(in: app, identifier: "first-run-continue")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 4),
                      "first-run cover must expose first-run-continue control")

        let skipButton = app.buttons["first-run-skip"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 4),
                      "Skip must be reachable from the first card")

        let title = app.staticTexts["first-run-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        XCTAssertEqual(title.label, "Только приём",
                       "fresh launch must surface the receiveOnly card first (PRD §1.3)")
    }

    @MainActor
    func testFirstRunAdvancesThroughAllThreeCards() {
        let app = launchFreshFirstRun()

        let continueButton = anyElement(in: app, identifier: "first-run-continue")
        let title = app.staticTexts["first-run-card-title"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(title.waitForExistence(timeout: 4))

        XCTAssertEqual(title.label, "Только приём")

        continueButton.tap()
        waitFor(title, toEqual: "Локально по умолчанию")

        continueButton.tap()
        waitFor(title, toEqual: "Подключите гарнитуру")

        let picker = anyElement(in: app, identifier: "first-run-target-language-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 4),
                      "language picker must surface on the last card (consumes TranslationLanguagePackManager DI)")
    }

    @MainActor
    func testFirstRunFinishDismissesCoverAndLandsOnLocalPrivacyBadge() {
        let app = launchFreshFirstRun()

        let continueButton = anyElement(in: app, identifier: "first-run-continue")
        let title = app.staticTexts["first-run-card-title"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(title.waitForExistence(timeout: 4))

        continueButton.tap() // → card 2
        waitFor(title, toEqual: "Локально по умолчанию")

        continueButton.tap() // → card 3
        waitFor(title, toEqual: "Подключите гарнитуру")

        continueButton.tap() // tap "Начать" → finish() → cover dismisses

        let cover = app.otherElements["first-run-view"]
        let coverGone = NSPredicate(format: "exists == false")
        expectation(for: coverGone, evaluatedWith: cover, handler: nil)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(app.staticTexts["Dspeech"].waitForExistence(timeout: 4),
                      "main surface must render after first-run completes")

        let badge = app.staticTexts["privacy-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 4),
                      "privacy LOCAL badge must be visible after first-run completes (ADR 0002 hard rule #4)")
        XCTAssertEqual(badge.label, "Локальная обработка",
                       "fresh install must land in PrivacyMode.localOnly")
    }

    @MainActor
    func testFirstRunSkipDismissesCoverImmediately() {
        let app = launchFreshFirstRun()

        let skipButton = app.buttons["first-run-skip"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 8))
        skipButton.tap()

        let cover = app.otherElements["first-run-view"]
        let coverGone = NSPredicate(format: "exists == false")
        expectation(for: coverGone, evaluatedWith: cover, handler: nil)
        waitForExpectations(timeout: 8)

        let badge = app.staticTexts["privacy-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 4))
        XCTAssertEqual(badge.label, "Локальная обработка")
    }

    @MainActor
    func testFirstRunCoverDoesNotPresentWhenAlreadyCompleted() {
        let app = XCUIApplication()
        // why: arg-domain `-hasCompletedFirstRun YES` wins over any persisted
        // value in `applyFirstRunLaunchOverride`'s `defaults.object(...) != nil`
        // branch — without this, residual state from a previous test in the
        // same simulator boot can flip the verdict.
        app.launchArguments += [
            "-hasCompletedFirstRun", "YES",
            "-dspeech.privacy.mode.v1", "localOnly"
        ]
        app.launchEnvironment["DSPEECH_UITEST"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Dspeech"].waitForExistence(timeout: 8),
                      "main surface must render immediately when first-run is already completed")
        XCTAssertFalse(app.buttons["first-run-skip"].exists,
                       "completed first-run must not surface the cover")
        XCTAssertTrue(app.staticTexts["privacy-badge"].exists)
    }

    // MARK: helpers

    @MainActor
    private func launchFreshFirstRun() -> XCUIApplication {
        let app = XCUIApplication()
        // `DSPEECH_FORCE_FIRST_RUN=1` wins unconditionally in
        // `applyFirstRunLaunchOverride()`, resetting persisted state so each
        // test sees a fresh install. `-hasCompletedFirstRun NO` is belt-and-
        // suspenders for the rare ordering where env vars are stripped.
        // `DSPEECH_UITEST=1` swaps in `UITestOnboardingPermissionRequester`
        // so the test does not stall on the real Speech/Mic system alerts.
        app.launchEnvironment["DSPEECH_FORCE_FIRST_RUN"] = "1"
        app.launchEnvironment["DSPEECH_UITEST"] = "1"
        app.launchArguments += ["-hasCompletedFirstRun", "NO"]
        app.launch()
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, toEqual expected: String, timeout: TimeInterval = 6) {
        let predicate = NSPredicate(format: "label == %@", expected)
        expectation(for: predicate, evaluatedWith: element, handler: nil)
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func anyElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
