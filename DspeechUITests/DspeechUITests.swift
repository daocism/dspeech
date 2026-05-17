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
    }
}
