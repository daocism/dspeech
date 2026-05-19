import SwiftUI

@main
struct DspeechApp: App {
    init() {
        DspeechApp.applyFirstRunLaunchOverride()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                audioService: AppleAudioInputService(),
                translationService: LocalTranslationService(backend: AppleTranslationService()),
                firstRunCoordinator: DefaultFirstRunCoordinator(),
                permissionRequester: DspeechApp.isUITesting
                    ? UITestOnboardingPermissionRequester()
                    : SystemOnboardingPermissionRequester()
            )
        }
    }

    private static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["DSPEECH_UITEST"] == "1"
    }

    /// Bridges the XCUITest launch overrides onto the first-run store key so
    /// the coordinator (`UserDefaultsFirstRunStateStore`, key
    /// `hasCompletedFirstRun`) reflects each test's intent deterministically.
    /// The harness sets the bare `-hasCompletedFirstRun` argument-domain key,
    /// never the prefixed store key, so the composition root mirrors it here.
    /// Production passes no launch arguments, so none of these branches fire
    /// and the real persisted flag is used unchanged.
    private static func applyFirstRunLaunchOverride() {
        let env = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        let storeKey = UserDefaultsFirstRunStateStore.completedDefaultsKey

        if env["DSPEECH_FORCE_FIRST_RUN"] == "1" {
            defaults.set(false, forKey: storeKey)
        } else if defaults.object(forKey: "hasCompletedFirstRun") != nil {
            defaults.set(defaults.bool(forKey: "hasCompletedFirstRun"), forKey: storeKey)
        } else if arguments.contains(where: { $0.hasPrefix("-dspeech.") }) {
            // why: the original DspeechUITests pass only -dspeech.privacy.mode.v1
            // and assert the transcript surface directly; a -dspeech.* launch
            // argument marks the UI-test harness (production passes none), so
            // skip onboarding unless a test explicitly forces it above.
            defaults.set(true, forKey: storeKey)
        }
    }
}

/// Real OS prompts are bypassed only under XCUITest so the first-run completion
/// flow does not present an un-monitored system permission alert mid-test. The
/// production composition root always injects `SystemOnboardingPermissionRequester`
/// (repo `CLAUDE.md` rule 2: no fake surface ships — this is test-only seam
/// wiring, gated strictly on `DSPEECH_UITEST`).
struct UITestOnboardingPermissionRequester: OnboardingPermissionRequesting {
    func requestSpeechAndMicrophone() async -> Bool { true }
}
