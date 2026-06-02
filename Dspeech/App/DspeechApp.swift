import AppIntents
import SwiftUI

@main
struct DspeechApp: App {
  #if DEBUG
    // why: the SFSpeech replay probe is a Debug/CI-only diagnostic launched via
    // `--dspeech-sfspeech-probe`; it must never be reachable in a release build that
    // ships to TestFlight / the App Store.
    private let probeFixturePaths: [String]
  #endif

  init() {
    #if DEBUG
      let arguments = CommandLine.arguments
      if let markerIndex = arguments.firstIndex(of: "--dspeech-sfspeech-probe") {
        probeFixturePaths = Array(arguments.dropFirst(markerIndex + 1))
      } else {
        probeFixturePaths = []
      }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if probeFixturePaths.isEmpty {
          ContentView()
        } else {
          SimulatorSpeechProbeView(fixturePaths: probeFixturePaths)
        }
      #else
        ContentView()
      #endif
    }
  }
}
