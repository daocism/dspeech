import AppIntents
import XCTest

final class DspeechUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testAppLaunchesToTranscriptSurface() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    XCTAssertTrue(app.staticTexts["Dspeech"].waitForExistence(timeout: 8))
    assertKnownDemoTranscriptAppears(in: app)
    assertLocalOnlyBadgeIsVisible(in: app)
    assertTranslationControlsAreAbsent(in: app)
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)
    XCTAssertTrue(app.buttons["settings-button"].exists)
  }

  @MainActor
  func testSettingsButtonOpensSettingsSheet() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    let settingsButton = app.buttons["settings-button"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
    settingsButton.tap()

    let doneButton = app.buttons["settings-done-button"]
    XCTAssertTrue(doneButton.waitForExistence(timeout: 4))
    XCTAssertTrue(app.navigationBars["Настройки"].exists)

    doneButton.tap()
    XCTAssertFalse(doneButton.waitForExistence(timeout: 2))
  }

  @MainActor
  func testPrivacyBadgeStaysLocalAndRemoteOptInControlIsAbsent() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    assertLocalOnlyBadgeIsVisible(in: app)
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)

    app.buttons["settings-button"].tap()
    assertTranslationControlsAreAbsent(in: app)
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)
    XCTAssertTrue(app.switches["voicefilter-active-toggle"].waitForExistence(timeout: 4))

    app.buttons["settings-done-button"].tap()

    assertLocalOnlyBadgeIsVisible(in: app)
  }

  @MainActor
  func testStartButtonDoesNotCrashAppWithPermissionsPreGranted() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    let startButton = app.buttons["start-button"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: 8),
      "main start-button must be reachable on launch")
    startButton.tap()

    let permissionAlertButton = app.alerts.element.buttons.matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
        "Разреш", "Allow")
    ).firstMatch
    if permissionAlertButton.waitForExistence(timeout: 3) {
      permissionAlertButton.tap()
    }

    let stopButton = app.buttons["stop-button"]
    let stopAppeared = stopButton.waitForExistence(timeout: 8)

    XCTAssertTrue(
      app.state == .runningForeground,
      "app must still be running (not crashed) after tapping start")
    XCTAssertTrue(
      stopAppeared || startButton.exists,
      "either listening started (stop-button) or engine reported failure (start-button stayed) — app must not crash"
    )
  }

  @MainActor
  func testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.voicefilter.modelpack.v1", "absent",
    ]
    app.launch()

    app.buttons["settings-button"].tap()

    let enabledToggle = app.switches["voicefilter-enabled-toggle"]
    XCTAssertTrue(
      enabledToggle.waitForExistence(timeout: 6),
      "voice-filter section must render")

    let downloadCTA = app.buttons["voicefilter-modelpack-download-cta"]
    var attempts = 0
    while !downloadCTA.exists && attempts < 8 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(
      downloadCTA.waitForExistence(timeout: 4),
      "download CTA must be present in the voice-filter section")
    XCTAssertTrue(
      downloadCTA.isEnabled,
      "download CTA must be enabled (no longer a disabled placeholder)")

    downloadCTA.tap()

    // why: with model files already cached, install can complete almost
    // instantly, so accept either the acquiring state or the installed result
    // as proof the download path is wired and ran.
    let cancel = app.buttons["voicefilter-modelpack-cancel"]
    let progress = app.progressIndicators["voicefilter-modelpack-progress"]
    let installed = app.staticTexts["Модель установлена и проверена"]
    let movedOff = NSPredicate(format: "exists == false")
    expectation(for: movedOff, evaluatedWith: downloadCTA, handler: nil)
    waitForExpectations(timeout: 8)
    XCTAssertTrue(
      cancel.exists || progress.exists || installed.exists,
      "tapping download must transition to acquiring or installed")

    if cancel.exists {
      cancel.tap()
    }
  }

  @MainActor
  func testVoiceFilterActiveKillSwitchDefaultsOnAndCanTurnOff() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    app.buttons["settings-button"].tap()

    let activeToggle = app.switches["voicefilter-active-toggle"]
    XCTAssertTrue(activeToggle.waitForExistence(timeout: 4))
    XCTAssertEqual(activeToggle.value as? String, "1")

    activeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    let switchedOff = NSPredicate(format: "value == %@", "0")
    expectation(for: switchedOff, evaluatedWith: activeToggle, handler: nil)
    waitForExpectations(timeout: 4)
  }

  @MainActor
  func testVoiceFilterRetryButtonIsEnabledForRetryableFailure() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.voicefilter.modelpack.v1", "failedRetryable",
    ]
    app.launch()

    app.buttons["settings-button"].tap()

    let retry = app.buttons["voicefilter-modelpack-retry"]
    var attempts = 0
    while !retry.exists && attempts < 8 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(retry.waitForExistence(timeout: 4))
    XCTAssertTrue(retry.isEnabled)
  }

  @MainActor
  func testVoiceFilterAcquisitionShowsPercentText() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.voicefilter.modelpack.v1", "acquiringHalf",
    ]
    app.launch()

    app.buttons["settings-button"].tap()

    let percent = app.staticTexts["voicefilter-modelpack-percent"]
    var attempts = 0
    while !percent.exists && attempts < 8 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(percent.waitForExistence(timeout: 4))
    XCTAssertEqual(percent.label, "42%")
  }

  @MainActor
  private func launchAppWithCleanPrivacyDefaults() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
    ]
    app.launch()
    return app
  }

  @MainActor
  private func assertKnownDemoTranscriptAppears(
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let firstDemoSegment =
      "N123AB, descend and maintain three thousand, expect ILS runway two seven approach."
    let secondDemoSegment = "Speedbird 42, contact tower one one eight decimal seven."

    XCTAssertTrue(
      app.staticTexts[firstDemoSegment].waitForExistence(timeout: 8),
      "known demo fixture transcript must render on launch",
      file: file,
      line: line
    )
    XCTAssertTrue(
      app.staticTexts[secondDemoSegment].exists,
      "second demo fixture transcript must render on launch",
      file: file,
      line: line
    )
  }

  @MainActor
  private func assertLocalOnlyBadgeIsVisible(
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let badge = app.staticTexts["privacy-badge"]
    XCTAssertTrue(
      badge.waitForExistence(timeout: 8),
      "privacy badge must stay visible on the main surface",
      file: file,
      line: line
    )
    XCTAssertEqual(
      badge.label,
      "Локальная обработка",
      "privacy badge must stay in local-only mode",
      file: file,
      line: line
    )
  }

  @MainActor
  private func assertTranslationControlsAreAbsent(
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(
      app.switches["translation-toggle"].exists,
      "fake translation toggle must not ship",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.staticTexts["Перевод"].exists,
      "translation settings section title must not ship until translation is real",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.staticTexts["Провайдер"].exists,
      "translation provider copy must not ship until translation is real",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.staticTexts["Целевой язык"].exists,
      "translation target-language copy must not ship until translation is real",
      file: file,
      line: line
    )
  }

  @MainActor
  private func assertCloudOrRemoteOptInControlsAreAbsent(
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(
      app.switches["cloud-toggle"].exists,
      "cloud opt-in toggle must not ship while local-only is the only mode",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.switches["Разрешить облачную обработку"].exists,
      "cloud opt-in switch must not be discoverable by visible label",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.staticTexts["Разрешить облачную обработку"].exists,
      "cloud opt-in copy must not ship while local-only is the only mode",
      file: file,
      line: line
    )
    XCTAssertFalse(
      app.staticTexts.matching(
        NSPredicate(
          format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
          "remote", "облач")
      ).firstMatch.exists,
      "remote/cloud opt-in copy must not appear in the UI",
      file: file,
      line: line
    )
  }
}
