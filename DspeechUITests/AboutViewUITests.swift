import XCTest

/// Surface-level coverage of `AboutView`: opened from the Settings sheet via
/// the `about-nav-link` row, must publish the version, the "локально на
/// устройстве" privacy badge (the in-About echo of ADR 0002 hard rule #4),
/// and the Apple Speech / Translation attributions that the AI-only repo
/// keeps in lieu of human-authored release-notes copy.
///
/// Each test forces `hasCompletedFirstRun=YES` via arg-domain so the cover
/// never blocks the Settings tap, regardless of prior simulator state.
///
/// Element-kind tolerance — `NavigationLink { … } label: { LabeledContent }`
/// + `.accessibilityElement(children: .combine)` lands under different XCUI
/// element kinds depending on SwiftUI's projection (cell, button, other).
/// The `anyElement(...)` helper queries by identifier across all kinds so a
/// future Form layout tweak doesn't break the suite for the wrong reason.
final class AboutViewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAboutLinkSurfacesInSettings() {
        let app = launchPostOnboarding()

        openSettings(app)

        let aboutLink = anyElement(in: app, identifier: "about-nav-link")
        XCTAssertTrue(aboutLink.waitForExistence(timeout: 6),
                      "Settings sheet must expose the About row")
    }

    @MainActor
    func testAboutViewShowsApplicationNameAndVersion() {
        let app = launchPostOnboarding()
        openAbout(app)

        let aboutView = anyElement(in: app, identifier: "about-view")
        XCTAssertTrue(aboutView.waitForExistence(timeout: 6))

        XCTAssertTrue(
            anyElement(in: app, identifier: "about-app-name").waitForExistence(timeout: 4),
            "About must label the application name"
        )
        XCTAssertTrue(
            anyElement(in: app, identifier: "about-version").waitForExistence(timeout: 4),
            "About must publish the bundle version"
        )
    }

    @MainActor
    func testAboutViewShowsLocalOnDeviceBadge() {
        let app = launchPostOnboarding()
        openAbout(app)

        let badge = anyElement(in: app, identifier: "about-privacy-badge")
        XCTAssertTrue(badge.waitForExistence(timeout: 6),
                      "ADR 0002 hard rule #4: About must echo the LOCAL on-device privacy posture")
        XCTAssertEqual(badge.label, "Локальная обработка на устройстве")
    }

    @MainActor
    func testAboutViewListsAppleSpeechAndTranslationAttributions() {
        let app = launchPostOnboarding()
        openAbout(app)

        XCTAssertTrue(
            anyElement(in: app, identifier: "about-attribution-apple-speech").waitForExistence(timeout: 6),
            "Apple Speech framework attribution must be present"
        )
        XCTAssertTrue(
            anyElement(in: app, identifier: "about-attribution-translation").waitForExistence(timeout: 4),
            "Apple Translation framework attribution must be present"
        )
    }

    @MainActor
    func testAboutViewIncludesLicensesSection() {
        let app = launchPostOnboarding()
        openAbout(app)

        XCTAssertTrue(
            anyElement(in: app, identifier: "about-licenses").waitForExistence(timeout: 6),
            "Licenses / system frameworks section must be present"
        )
    }

    // MARK: helpers

    @MainActor
    private func launchPostOnboarding() -> XCUIApplication {
        let app = XCUIApplication()
        // `-hasCompletedFirstRun YES` wins over any persisted value via
        // `defaults.object(...)` in `applyFirstRunLaunchOverride()`, so the
        // cover never blocks the Settings tap.
        app.launchArguments += [
            "-hasCompletedFirstRun", "YES",
            "-dspeech.privacy.mode.v1", "localOnly"
        ]
        app.launchEnvironment["DSPEECH_UITEST"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()
        XCTAssertTrue(app.buttons["settings-done-button"].waitForExistence(timeout: 4))
    }

    @MainActor
    private func openAbout(_ app: XCUIApplication) {
        openSettings(app)
        let aboutLink = anyElement(in: app, identifier: "about-nav-link")
        if !aboutLink.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(aboutLink.waitForExistence(timeout: 4))
        if !aboutLink.isHittable {
            app.swipeUp()
        }
        aboutLink.tap()
    }

    @MainActor
    private func anyElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
