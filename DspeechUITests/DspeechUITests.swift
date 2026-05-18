import XCTest

final class DspeechUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesToTranscriptSurface() throws {
        let app = launchAppWithCleanPrivacyDefaults()

        XCTAssertTrue(app.staticTexts["Dspeech"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches["translation-toggle"].exists)
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
    func testPrivacyBadgeStartsLocalAndFlipsToCloudOnOptIn() throws {
        let app = launchAppWithCleanPrivacyDefaults()

        let badge = app.staticTexts["privacy-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertEqual(badge.label, "Локальная обработка")

        app.buttons["settings-button"].tap()
        let cloudToggle = app.switches["cloud-toggle"]
        XCTAssertTrue(cloudToggle.waitForExistence(timeout: 4))
        XCTAssertEqual(cloudToggle.value as? String, "0")

        cloudToggle.tap()
        XCTAssertEqual(cloudToggle.value as? String, "1")

        app.buttons["settings-done-button"].tap()

        let cloudBadge = app.staticTexts["privacy-badge"]
        XCTAssertTrue(cloudBadge.waitForExistence(timeout: 4))
        XCTAssertEqual(cloudBadge.label, "Облачная обработка (с согласия)")
    }

    @MainActor
    private func launchAppWithCleanPrivacyDefaults() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-dspeech.privacy.mode.v1", "localOnly"
        ]
        app.launch()
        return app
    }
}
