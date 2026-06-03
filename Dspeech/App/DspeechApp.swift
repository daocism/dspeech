import AppIntents
import SwiftUI

@main
struct DspeechApp: App {
  #if DEBUG
    // why: the SFSpeech replay probe is a Debug/CI-only diagnostic launched via
    // `--dspeech-sfspeech-probe`; it must never be reachable in a release build that
    // ships to TestFlight / the App Store.
    private let probeFixturePaths: [String]
    private let recognitionAvailabilityOverride: (any OnDeviceLocaleAvailability)?
  #endif

  init() {
    #if DEBUG
      let arguments = CommandLine.arguments
      if let markerIndex = arguments.firstIndex(of: "--dspeech-sfspeech-probe") {
        probeFixturePaths = Array(arguments.dropFirst(markerIndex + 1))
      } else {
        probeFixturePaths = []
      }
      if arguments.contains("--dspeech-recognition-no-locales") {
        recognitionAvailabilityOverride = DebugRecognitionLocaleAvailability(
          capable: [],
          downloaded: []
        )
      } else {
        recognitionAvailabilityOverride = nil
      }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if probeFixturePaths.isEmpty {
          ContentView(recognitionAvailability: recognitionAvailabilityOverride)
        } else {
          SimulatorSpeechProbeView(fixturePaths: probeFixturePaths)
        }
      #else
        ContentView()
      #endif
    }
  }
}

#if DEBUG
  private struct DebugRecognitionLocaleAvailability: OnDeviceLocaleAvailability {
    let capable: Set<Locale>
    let downloaded: Set<String>

    func capableLocales() async -> Set<Locale> { capable }
    func isDownloaded(_ locale: Locale) async -> Bool {
      downloaded.contains(locale.identifier)
    }
  }
#endif
