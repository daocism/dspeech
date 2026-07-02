import AppIntents
import UIKit
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
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)
    XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 4))
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
  func testSessionHistoryButtonExists() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    XCTAssertTrue(
      app.buttons["session-history-button"].waitForExistence(timeout: 8),
      "history button must be reachable on the main surface")
  }

  // E4 — the iPad split shell. On regular width the app adopts a NavigationSplitView: the sidebar
  // is the navigation (Live / History / Settings) and the detail column hosts the cockpit or the
  // re-housed History/Settings views as COLUMNS (not sheets). Landscape is forced so the sidebar is
  // shown alongside the detail (portrait collapses it behind the system toggle). The LOCAL badge is
  // the hard-gate element (rule 4) and must stay visible on the live cockpit column.
  @MainActor
  func testIPadSplitShellSidebarNavigatesLiveHistoryAndSettingsColumns() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else {
      throw XCTSkip("iPad-only regular-width split-shell smoke")
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.uitest.reduce-animations"])

    // the split sidebar exposes the three navigation destinations
    let liveItem = sidebarItem("sidebar-live", in: app)
    let historyItem = sidebarItem("sidebar-history", in: app)
    let settingsItem = sidebarItem("sidebar-settings", in: app)
    XCTAssertTrue(
      liveItem.waitForExistence(timeout: 10), "split sidebar must expose a Live destination")
    XCTAssertTrue(historyItem.exists, "split sidebar must expose a History destination")
    XCTAssertTrue(settingsItem.exists, "split sidebar must expose a Settings destination")

    // the default column is the live cockpit — the transcript surface is reachable and the
    // LOCAL badge is visible on it (hard rule 4 holds on iPad)
    XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 8))
    assertLocalOnlyBadgeIsVisible(in: app)
    captureAttachment(app, "ipad-landscape-live-sidebar")

    // Settings opens as a DETAIL COLUMN, not a sheet
    tapSidebar(settingsItem)
    XCTAssertTrue(
      app.buttons["settings-done-button"].waitForExistence(timeout: 8),
      "Settings must render as a detail column on iPad regular width")
    captureAttachment(app, "ipad-landscape-settings-column")

    // History opens as a DETAIL COLUMN, not a sheet
    tapSidebar(historyItem)
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "session-history-list").firstMatch.waitForExistence(timeout: 8),
      "Session history must render as a detail column on iPad regular width")
    captureAttachment(app, "ipad-landscape-history-column")

    // back to the live cockpit — the badge and start control are present again
    tapSidebar(liveItem)
    XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 8))
    assertLocalOnlyBadgeIsVisible(in: app)
  }

  // the in-cockpit control-bar gear/history buttons also drive the sidebar selection on iPad —
  // tapping the gear navigates the detail column to Settings (no sheet), proving the adaptive
  // routing (presentSettings/presentHistory) keeps every entry point coherent with the layout.
  @MainActor
  func testIPadControlBarButtonsNavigateDetailColumnsNotSheets() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else {
      throw XCTSkip("iPad-only regular-width routing smoke")
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.uitest.reduce-animations"])

    let settingsButton = app.buttons["settings-button"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntilHittable(settingsButton))
    settingsButton.tap()
    XCTAssertTrue(
      app.buttons["settings-done-button"].waitForExistence(timeout: 8),
      "control-bar gear must navigate to the Settings detail column on iPad")

    // return to Live via the sidebar, then exercise the history control-bar button
    tapSidebar(sidebarItem("sidebar-live", in: app))

    let historyButton = app.buttons["session-history-button"]
    XCTAssertTrue(historyButton.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(historyButton))
    historyButton.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "session-history-list").firstMatch.waitForExistence(timeout: 8),
      "control-bar history button must navigate to the History detail column on iPad")
  }

  @MainActor
  private func sidebarItem(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  // why: a split-view sidebar row's accessibilityIdentifier resolves to its label text, which
  // reports isHittable == false inside a selectable List row (the row/cell is the interactive
  // element, not the label). A coordinate tap on the resolved frame drives the same
  // NavigationSplitView selection a user tap would, without gating on the label's hittability.
  @MainActor
  private func tapSidebar(_ element: XCUIElement) {
    XCTAssertTrue(element.waitForExistence(timeout: 8), "sidebar row must exist before tap")
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  @MainActor
  func testClearShowsConfirmation() throws {
    // why: confirmationDialog renders through UIKit's alert controller, which drops
    // SwiftUI accessibility identifiers — the dialog button is only reachable by its
    // visible title, so this test pins the locale to English explicitly.
    let app = launchAppWithSeededSuppressedSegment(
      extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])

    let clear = app.buttons["clear-button"]
    XCTAssertTrue(clear.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(clear))
    clear.tap()

    XCTAssertTrue(
      app.buttons["Clear view"].waitForExistence(timeout: 4),
      "clear must require confirmation before resetting the view")
  }

  @MainActor
  func testSeededSuppressedSegmentShowsReviewSheet() throws {
    let app = launchAppWithSeededSuppressedSegment()

    let pill = app.descendants(matching: .any)
      .matching(identifier: "filtered-transmissions-pill").firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(pill))
    pill.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "filtered-review-sheet").firstMatch.waitForExistence(timeout: 4),
      "filtered-transmissions pill must open the filtered-transmission review sheet")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "transmission-reason-badge").firstMatch.exists)
    XCTAssertTrue(app.buttons["show-suppressed-segment"].exists)
  }

  @MainActor
  func testPrivacyBadgeStaysLocalAndRemoteOptInControlIsAbsent() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    assertLocalOnlyBadgeIsVisible(in: app)
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)

    app.buttons["settings-button"].tap()
    assertCloudOrRemoteOptInControlsAreAbsent(in: app)

    app.buttons["settings-done-button"].tap()

    assertLocalOnlyBadgeIsVisible(in: app)
  }

  @MainActor
  func testSpeakerClassificationToggleVisibleByDefault() throws {
    let app = launchAppWithCleanPrivacyDefaults()

    app.buttons["settings-button"].tap()

    XCTAssertTrue(
      app.switches["voicefilter-active-toggle"].waitForExistence(timeout: 4),
      "speaker-classification switch must be reachable in the shipping default build")
  }

  @MainActor
  func testSpeakerClassificationToggleHiddenWhenDiarizationDisabled() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.voicefilter.diarization.disable"])

    app.buttons["settings-button"].tap()

    XCTAssertFalse(
      app.switches["voicefilter-active-toggle"].waitForExistence(timeout: 1),
      "speaker-classification switch must be hidden when diarization is force-disabled")
  }

  @MainActor
  func testStartTransitionsToListeningOrVisibleFailure() throws {
    let app = launchAppWithCleanPrivacyDefaults()
    addUIInterruptionMonitor(withDescription: "Speech and microphone permissions") { alert in
      Self.tapPermissionButton(in: alert)
    }

    let startButton = app.buttons["start-button"]
    XCTAssertTrue(
      startButton.waitForExistence(timeout: 8),
      "main start-button must be reachable on launch")
    startButton.tap()
    app.tap()

    acceptPermissionAlertsIfPresent(in: app)

    let reachedStartOutcome = waitForStartOutcome(in: app)

    XCTAssertTrue(
      app.state == .runningForeground,
      "app must still be running (not crashed) after tapping start")
    XCTAssertTrue(
      reachedStartOutcome,
      "tapping Start must reach listening UI or a visible typed failure")

    if app.buttons["stop-button"].exists {
      app.buttons["stop-button"].tap()
      XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 4))
    } else {
      let errorBanner = app.staticTexts["error-banner"]
      XCTAssertTrue(errorBanner.exists)
      XCTAssertFalse(errorBanner.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    assertLocalOnlyBadgeIsVisible(in: app)
  }

  @MainActor
  func testScriptedEngineShowsPartialFinalAndClearFlow() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-dspeech.uitest.scripted-engine",
        "-dspeech.uitest.reduce-animations",
      ])

    let startButton = app.buttons["start-button"]
    XCTAssertTrue(startButton.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(startButton))
    startButton.tap()

    let partialCard = app.descendants(matching: .any)
      .matching(identifier: "partial-transcript").firstMatch
    XCTAssertTrue(partialCard.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Tower N123AB"].waitForExistence(timeout: 4))

    XCTAssertTrue(
      app.staticTexts["Tower N123AB cleared for takeoff"].waitForExistence(timeout: 8),
      "scripted final segment text must render")
    let finalTransmission = app.descendants(matching: .any)
      .matching(identifier: "transmission-card").firstMatch
    XCTAssertTrue(
      finalTransmission.waitForExistence(timeout: 4),
      "scripted final speech must render as a permanent transmission card")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "transmission-reason-badge").firstMatch.waitForExistence(timeout: 4),
      "final card must expose the transmission classification reason")

    let clear = app.buttons["clear-button"]
    XCTAssertTrue(clear.waitForExistence(timeout: 4))
    XCTAssertTrue(waitUntilHittable(clear))
    clear.tap()

    let clearView = app.buttons["Clear view"]
    XCTAssertTrue(clearView.waitForExistence(timeout: 4))
    clearView.tap()

    XCTAssertTrue(app.staticTexts["transcript-empty-state"].waitForExistence(timeout: 4))
    XCTAssertTrue(waitUntilGone(finalTransmission))
    XCTAssertTrue(waitUntilGone(partialCard))
  }

  @MainActor
  private func acceptPermissionAlertsIfPresent(in app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for _ in 0..<3 {
      if app.alerts.element.waitForExistence(timeout: 1),
        Self.tapPermissionButton(in: app.alerts.element)
      {
        continue
      }
      if springboard.alerts.element.waitForExistence(timeout: 1),
        Self.tapPermissionButton(in: springboard.alerts.element)
      {
        continue
      }
      return
    }
  }

  @MainActor
  private static func tapPermissionButton(in alert: XCUIElement) -> Bool {
    let preferred = alert.buttons.matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
        "Разреш", "Allow")
    ).firstMatch
    if preferred.exists {
      preferred.tap()
      return true
    }
    let count = alert.buttons.count
    guard count > 0 else { return false }
    alert.buttons.element(boundBy: count - 1).tap()
    return true
  }

  @MainActor
  private func waitForStartOutcome(in app: XCUIApplication) -> Bool {
    let emptyState = app.staticTexts["transcript-empty-state"]
    let errorBanner = app.staticTexts["error-banner"]
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      acceptPermissionAlertsIfPresent(in: app)
      if app.buttons["stop-button"].exists && emptyState.exists
        && emptyState.label.localizedCaseInsensitiveContains("Слушаю")
      {
        return true
      }
      if errorBanner.exists
        && !errorBanner.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  @MainActor
  func testVoiceFilterModelPackDownloadCTAIsEnabledAndStartsAcquisition() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.voicefilter.diarization.enable",
      "-dspeech.voicefilter.modelpack.v1", "absent",
    ]
    app.launch()

    openSettings(in: app)

    let enabledToggle = app.switches["voicefilter-enabled-toggle"]
    XCTAssertTrue(
      enabledToggle.waitForExistence(timeout: 6),
      "voice-filter section must render")

    let downloadCTA = app.buttons["voicefilter-modelpack-download-cta"]
    XCTAssertTrue(
      scrollToHittable(downloadCTA, in: app),
      "download CTA must become hittable in the voice-filter section")
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

    // why: acquisition can finish between the `exists` check and a tap on hosted CI;
    // the transition assertion above is the behavior under test, and app termination handles cleanup.
  }

  @MainActor
  func testVoiceFilterActiveKillSwitchDefaultsOnAndCanTurnOffWhenDiarizationEnabled() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.voicefilter.diarization.enable"])

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
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.voicefilter.diarization.enable",
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
  func testCorruptVoiceFilterStorageShowsRecoveryBanner() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.voicefilter.enabled.v1", "not-a-bool",
    ]
    app.launch()

    openSettings(in: app)

    let banner = app.descendants(matching: .any)
      .matching(identifier: "voicefilter-storage-corrupt").firstMatch
    XCTAssertTrue(
      scrollToHittable(banner, in: app),
      "corrupt-storage recovery banner must become visible in settings")
    XCTAssertTrue(app.buttons["voicefilter-storage-recovery"].exists)
  }

  @MainActor
  func testCorruptModelPackStateShowsContinueWithoutPath() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.voicefilter.diarization.enable",
      "-dspeech.voicefilter.modelpack.v1", "not-a-model-pack-state",
    ]
    app.launch()

    openSettings(in: app)

    let failed = app.descendants(matching: .any)
      .matching(identifier: "voicefilter-modelpack-failed").firstMatch
    var attempts = 0
    while !failed.exists && attempts < 8 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(failed.waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["voicefilter-modelpack-retry"].exists)
    XCTAssertTrue(app.buttons["voicefilter-modelpack-continue-without"].exists)
  }

  @MainActor
  func testVoiceFilterAcquisitionShowsPercentText() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.voicefilter.diarization.enable",
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
  func testFirstRunOnboardingShowsCardsThenRevealsTranscript() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "false",
    ]
    app.launch()

    XCTAssertTrue(
      app.staticTexts["Только приём"].waitForExistence(timeout: 8),
      "first run must show the onboarding receive-only card")
    XCTAssertFalse(
      app.buttons["onboarding-done-button"].exists,
      "done button must only appear on the last card")

    for _ in 0..<2 {
      let next = app.buttons["onboarding-next-button"]
      XCTAssertTrue(next.waitForExistence(timeout: 4))
      next.tap()
    }

    let done = app.buttons["onboarding-done-button"]
    XCTAssertTrue(
      done.waitForExistence(timeout: 4),
      "advancing to the last card must reveal the done button")
    done.tap()

    XCTAssertTrue(
      app.staticTexts["Dspeech"].waitForExistence(timeout: 6),
      "completing onboarding must reveal the transcript surface")
    XCTAssertFalse(
      app.staticTexts["Только приём"].waitForExistence(timeout: 2),
      "onboarding must be dismissed after completion")
  }

  @MainActor
  func testSettingsExposesOnDeviceTranslationControls() throws {
    let app = launchAppWithCleanPrivacyDefaults()
    app.buttons["settings-button"].tap()

    let enableToggle = app.switches["translation-enabled-toggle"]
    var attempts = 0
    while !enableToggle.exists && attempts < 14 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(
      enableToggle.waitForExistence(timeout: 4),
      "settings must expose an on-device translation toggle")

    // the picker sits just below the toggle in the same section — scroll on until it renders
    let picker = app.descendants(matching: .any)
      .matching(identifier: "translation-target-picker").firstMatch
    var pickerAttempts = 0
    while !picker.exists && pickerAttempts < 8 {
      app.swipeUp()
      pickerAttempts += 1
    }
    XCTAssertTrue(
      picker.waitForExistence(timeout: 4),
      "settings must expose a target-language picker")
  }

  @MainActor
  func testSettingsShowsNoOnDeviceRecognitionLocaleState() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "--dspeech-recognition-no-locales",
    ]
    app.launch()

    openSettings(in: app)

    let unavailable = app.descendants(matching: .any)
      .matching(identifier: "recognition-locale-unavailable").firstMatch
    XCTAssertTrue(
      scrollToHittable(unavailable, in: app),
      "settings must surface an explicit no-on-device-recognition-locale state")
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(identifier: "recognition-locale-picker").firstMatch.exists,
      "settings must not show an empty picker with a fake selected locale")
  }

  @MainActor
  func testSettingsExposesAudioSourceSection() throws {
    let app = launchAppWithCleanPrivacyDefaults()
    app.buttons["settings-button"].tap()

    let header = app.staticTexts["Источник звука"]
    var attempts = 0
    while !header.exists && attempts < 12 {
      app.swipeUp()
      attempts += 1
    }
    XCTAssertTrue(
      header.waitForExistence(timeout: 4),
      "settings must expose an audio source section")
  }

  // F9 — scripted live transcript with on-device translation enabled SIMULTANEOUSLY. Proves that
  // arming translation does not break the transcript flow (partial -> final card render exactly as
  // without translation) and does not masquerade as a recognition failure. On a simulator with no
  // downloaded language pack the designed translation path is a rendered gloss, the designed
  // translation-failure banner, or Apple's system download sheet — never a crash, a blank
  // transcript, or the recognition error banner. Assertions are existence-based so a system
  // translation sheet compositing over the app cannot flake the transcript checks.
  @MainActor
  func testScriptedLiveWithTranslationEnabledKeepsTranscriptIntact() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-dspeech.uitest.scripted-engine",
        "-dspeech.uitest.reduce-animations",
        "-dspeech.translation.enabled.v1", "true",
        "-dspeech.translation.target.v1", "de",
      ])

    let start = app.buttons["start-button"]
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(start))
    start.tap()

    let partialCard = app.descendants(matching: .any)
      .matching(identifier: "partial-transcript").firstMatch
    XCTAssertTrue(
      partialCard.waitForExistence(timeout: 8),
      "partial hypothesis must still render live with translation enabled")
    XCTAssertTrue(app.staticTexts["Tower N123AB"].waitForExistence(timeout: 4))

    XCTAssertTrue(
      app.staticTexts["Tower N123AB cleared for takeoff"].waitForExistence(timeout: 8),
      "scripted final segment must still render as a card with translation enabled")
    let finalTransmission = app.descendants(matching: .any)
      .matching(identifier: "transmission-card").firstMatch
    XCTAssertTrue(finalTransmission.waitForExistence(timeout: 4))

    // honest translation outcome — the transcript survived and translation did not surface as a
    // recognition failure. (This does NOT claim a gloss was produced: the sim may have no de pack.)
    XCTAssertEqual(
      app.state, .runningForeground, "translation enabled must not crash the live flow")
    XCTAssertFalse(
      app.staticTexts["error-banner"].exists,
      "translation-enabled must never surface a RECOGNITION failure banner")

    // if a translation failure IS surfaced it must be the DESIGNED banner, and a failed
    // translation must not simultaneously render a gloss (that would be a fake-AI translation).
    let translationBanner = app.descendants(matching: .any)
      .matching(identifier: "translation-failure-banner").firstMatch
    if translationBanner.exists {
      XCTAssertFalse(
        app.descendants(matching: .any)
          .matching(identifier: "transcript-translation").firstMatch.exists,
        "a designed translation failure must not also render a gloss line")
    }
  }

  // F10 — permission denied -> Open Settings deep link -> honest re-request. The scripted-fail
  // engine drives a microphone-permission-denied failure; the banner must offer an Open Settings
  // deep link that backgrounds the app into iOS Settings, and returning must NOT fake a recovery:
  // re-tapping Start re-attempts and re-fails (only the OS can grant), leaving the same affordance.
  @MainActor
  func testPermissionDeniedOpensSettingsDeepLinkAndReRequestStaysHonest() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-dspeech.uitest.scripted-engine",
        "-dspeech.uitest.scripted-fail", "microphone-permission-denied",
        "-dspeech.uitest.reduce-animations",
      ])

    let start = app.buttons["start-button"]
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(start))
    start.tap()

    let banner = app.staticTexts["error-banner"]
    XCTAssertTrue(
      banner.waitForExistence(timeout: 12), "permission denial must surface the failure banner")
    XCTAssertFalse(
      banner.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "denial banner must carry a user-readable message")

    let openSettings = app.buttons["open-settings-button"]
    XCTAssertTrue(
      openSettings.waitForExistence(timeout: 6),
      "permission-denied banner must expose an Open Settings deep link")
    XCTAssertTrue(waitUntilHittable(openSettings))

    // a failed start must not strand the user in a fake listening state
    XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 6))
    XCTAssertFalse(app.buttons["stop-button"].exists)

    openSettings.tap()
    let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    let deepLinkedOut =
      settingsApp.wait(for: .runningForeground, timeout: 12)
      || app.wait(for: .runningBackground, timeout: 12)
    XCTAssertTrue(deepLinkedOut, "Open Settings must deep-link out to the iOS Settings app")

    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

    // re-request stays honest: the app cannot self-grant permission, so tapping Start again
    // re-attempts and re-fails into the same denial affordance — no magical recovery.
    let startAgain = app.buttons["start-button"]
    XCTAssertTrue(startAgain.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(startAgain))
    startAgain.tap()
    XCTAssertTrue(
      app.staticTexts["error-banner"].waitForExistence(timeout: 8),
      "returning from Settings must not fake a recovery — the denial persists on retry")
    XCTAssertTrue(
      app.buttons["open-settings-button"].waitForExistence(timeout: 6),
      "the Open Settings affordance must remain until the OS actually grants access")
    XCTAssertFalse(
      app.buttons["stop-button"].exists,
      "a still-denied retry must never enter a listening state")
  }

  // F12 — dark-lock consistency. The app forces `.preferredColorScheme(.dark)`, so its chrome must
  // render dark regardless of the SYSTEM appearance. XCUITest cannot set the simulator appearance,
  // so this is a falsifiable RENDER check: the Settings Form uses the system grouped background —
  // the surface that would render bright if the dark-lock did not hold under a light system. A
  // light Form averages > 0.6 luminance; a dark-locked Form averages < 0.35. The verification run
  // forces the simulator to LIGHT appearance to prove the override; the check also stands as a
  // dark-render regression guard under any system appearance. Screenshots are attached for eyes-on.
  @MainActor
  func testDarkLockRendersDarkChromeRegardlessOfSystemAppearance() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.uitest.reduce-animations"])

    // the LOCAL badge is the hard-gate element (rule 4) — it must be present on the dark chrome
    XCTAssertTrue(app.staticTexts["privacy-badge"].waitForExistence(timeout: 8))
    captureAttachment(app, "dark-lock-main")

    openSettings(in: app)
    captureAttachment(app, "dark-lock-settings")

    let region = CGRect(x: 0.15, y: 0.55, width: 0.70, height: 0.35)
    let luminance = try XCTUnwrap(
      meanLuminance(of: app.screenshot(), region: region),
      "must be able to sample the rendered settings surface")
    XCTAssertLessThan(
      luminance, 0.35,
      "dark-locked settings must render dark chrome (mean luminance \(luminance)) — the app's "
        + "forced dark scheme must override the system appearance")
  }

  // F14 — VoiceOver affordance for the transmission card's tap-to-expand. The card now carries an
  // accessibilityHint + a named "Show details" accessibilityAction that call the SAME
  // `expanded.toggle()` as the sighted tap. XCUITest cannot invoke a named a11y action or read a
  // hint, so this drives the shared toggle through the tap and asserts the timing detail row the
  // action reveals — the affordance's presence/wording is verified by code review + the l10n keys.
  @MainActor
  func testTransmissionCardTapToExpandRevealsTimingDetails() throws {
    let app = launchAppWithCleanPrivacyDefaults(
      extraArguments: [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-dspeech.uitest.scripted-engine",
        "-dspeech.uitest.reduce-animations",
      ])

    let start = app.buttons["start-button"]
    XCTAssertTrue(start.waitForExistence(timeout: 8))
    XCTAssertTrue(waitUntilHittable(start))
    start.tap()

    let finalText = app.staticTexts["Tower N123AB cleared for takeoff"]
    XCTAssertTrue(
      finalText.waitForExistence(timeout: 10), "scripted final transmission card must render")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "transmission-card").firstMatch.waitForExistence(timeout: 4))

    let details = app.descendants(matching: .any)
      .matching(identifier: "transmission-details").firstMatch
    XCTAssertFalse(details.exists, "timing detail must be collapsed until the card is activated")

    XCTAssertTrue(waitUntilHittable(finalText))
    finalText.tap()
    XCTAssertTrue(
      details.waitForExistence(timeout: 4),
      "activating the card must reveal the timing detail row (the accessibilityAction path)")

    finalText.tap()
    XCTAssertTrue(
      waitUntilGone(details), "activating the card again must hide the timing detail row")
  }

  // why: the recurring UI-test flake is interacting with a control before it is actually
  // hittable — the settings button tapped at launch before the toolbar settles, or a CTA tapped
  // while still off-screen. `.exists` becomes true before a control is laid out and hit-testable,
  // so existence-gated scrolls/taps race the render. These helpers gate on `.isHittable` and on
  // the settings sheet finishing presentation, removing the need for a retry to paper over it.
  @MainActor
  @discardableResult
  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
    let predicate = NSPredicate(format: "isHittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  @MainActor
  @discardableResult
  private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  @MainActor
  private func openSettings(
    in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let settingsButton = app.buttons["settings-button"]
    XCTAssertTrue(
      settingsButton.waitForExistence(timeout: 8),
      "settings button must be reachable on the main surface", file: file, line: line)
    XCTAssertTrue(
      waitUntilHittable(settingsButton),
      "settings button must become hittable before tap", file: file, line: line)
    settingsButton.tap()
    XCTAssertTrue(
      app.buttons["settings-done-button"].waitForExistence(timeout: 8),
      "settings sheet must finish presenting before interacting", file: file, line: line)
  }

  @MainActor
  @discardableResult
  private func scrollToHittable(
    _ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10
  ) -> Bool {
    var swipes = 0
    while swipes < maxSwipes {
      if element.exists && element.isHittable { return true }
      app.swipeUp()
      swipes += 1
    }
    return element.exists && element.isHittable
  }

  @MainActor
  private func captureAttachment(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  // why: F12 — XCUITest exposes no color-scheme trait, so dark-lock is verified by sampling the
  // rendered pixels. Returns the mean perceptual luminance (0…1) over a normalized sub-rectangle
  // of the screenshot, downsampled on a 4×4 grid for speed. A dark surface averages low, a light
  // surface averages high — a falsifiable signal, not a color read from the app under test.
  @MainActor
  private func meanLuminance(of screenshot: XCUIScreenshot, region: CGRect) -> Double? {
    guard let cgImage = screenshot.image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard
      let context = CGContext(
        data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let x0 = max(0, Int(Double(width) * Double(region.minX)))
    let x1 = min(width, Int(Double(width) * Double(region.maxX)))
    let y0 = max(0, Int(Double(height) * Double(region.minY)))
    let y1 = min(height, Int(Double(height) * Double(region.maxY)))
    guard x1 > x0, y1 > y0 else { return nil }

    var sum = 0.0
    var count = 0
    var y = y0
    while y < y1 {
      var x = x0
      while x < x1 {
        let index = y * bytesPerRow + x * bytesPerPixel
        let r = Double(raw[index])
        let g = Double(raw[index + 1])
        let b = Double(raw[index + 2])
        sum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        count += 1
        x += 4
      }
      y += 4
    }
    return count > 0 ? sum / Double(count) : nil
  }

  @MainActor
  private func launchAppWithCleanPrivacyDefaults(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
      "-dspeech.privacy.mode.v1", "localOnly",
      "-dspeech.privacy.voicefilter.active.v1", "true",
      "-dspeech.onboarding.completed.v1", "true",
      "-dspeech.first-session.has-ever-started.v1", "false",
      "-dspeech.transmission.no-anchor-hint-shown.v1", "false",
    ]
    app.launchArguments += extraArguments
    app.launch()
    return app
  }

  @MainActor
  private func launchAppWithSeededSuppressedSegment(
    extraArguments: [String] = []
  ) -> XCUIApplication {
    launchAppWithCleanPrivacyDefaults(
      extraArguments: ["-dspeech.uitest.seed-suppressed"] + extraArguments)
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
  }
}
