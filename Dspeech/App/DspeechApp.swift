import AppIntents
import SwiftUI

@main
struct DspeechApp: App {
  private let probeFixturePaths: [String]

  init() {
    let arguments = CommandLine.arguments
    if let markerIndex = arguments.firstIndex(of: "--dspeech-sfspeech-probe") {
      probeFixturePaths = Array(arguments.dropFirst(markerIndex + 1))
    } else {
      probeFixturePaths = []
    }
  }

  var body: some Scene {
    WindowGroup {
      if probeFixturePaths.isEmpty {
        ContentView()
      } else {
        SimulatorSpeechProbeView(fixturePaths: probeFixturePaths)
      }
    }
  }
}
