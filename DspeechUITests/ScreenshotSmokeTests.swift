import XCTest

// Lightweight page-snapshot smoke. Captures full-frame screenshots of the MAIN product
// surfaces so layout regressions are visible at a glance, without the heavy
// `performAccessibilityAudit` / Dynamic-Type / multi-locale sweeps (those live in
// AccessibilityAuditUITests, which the core test plan skips while the main flows are
// still being built). One app launch per flow keeps simulator boots to a minimum.
final class ScreenshotSmokeTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testCaptureMainAndSettingsPages() throws {
    let app = launchClean()

    XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 8))
    capture(app, "01-main-surface")

    let settings = app.buttons["settings-button"]
    XCTAssertTrue(settings.waitForExistence(timeout: 4))
    settings.tap()
    XCTAssertTrue(app.buttons["settings-done-button"].waitForExistence(timeout: 8))
    capture(app, "02-settings")
  }

  @MainActor
  func testCaptureFirstRunOnboardingPages() throws {
    let app = launchClean(onboardingCompleted: false)

    XCTAssertTrue(
      app.staticTexts["Только справочно"].waitForExistence(timeout: 8),
      "first run must show the safety advisory card first")
    capture(app, "03-onboarding-card-1")

    for index in 2...4 {
      let next = app.buttons["onboarding-next-button"]
      guard next.waitForExistence(timeout: 4) else { break }
      next.tap()
      capture(app, "03-onboarding-card-\(index)")
    }
  }

  @MainActor
  func testCaptureLiveTranscriptionPages() throws {
    let app = launchClean(
      extraArguments: [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-dspeech.uitest.scripted-engine",
        "-dspeech.uitest.reduce-animations",
      ])

    let start = app.buttons["start-button"]
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    start.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "partial-transcript").firstMatch.waitForExistence(timeout: 8))
    capture(app, "04-live-partial-transcript")

    XCTAssertTrue(
      app.staticTexts["Tower N123AB cleared for takeoff"].waitForExistence(timeout: 8),
      "scripted final segment text must render")
    capture(app, "05-live-final-transmission")
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  @MainActor
  private func launchClean(
    onboardingCompleted: Bool = true,
    extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", onboardingCompleted ? "true" : "false",
      "-dspeech.first-session.has-ever-started.v1", "false",
      "-dspeech.transmission.no-anchor-hint-shown.v1", "false",
    ]
    app.launchArguments += extraArguments
    app.launch()
    return app
  }
}
