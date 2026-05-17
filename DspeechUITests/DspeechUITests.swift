import XCTest

final class DspeechUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesToTranscriptSurface() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Dspeech"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches["translation-toggle"].exists)
        XCTAssertTrue(app.buttons["settings-button"].exists)
    }

    @MainActor
    func testSettingsButtonOpensSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()

        let doneButton = app.buttons["settings-done-button"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["Настройки"].exists)

        doneButton.tap()
        XCTAssertFalse(doneButton.waitForExistence(timeout: 2))
    }
}
