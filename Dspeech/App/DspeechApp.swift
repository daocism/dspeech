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

  // why: H5 — the MetricKit subscriber is an app-lifecycle singleton; it lives on the App (not in a
  // SwiftUI body) and starts once at launch so crash/hang/metric payloads are captured on device.
  // Settings reads the same Diagnostics directory through its own collector instance for the export
  // ShareLink. Local-only (ADR 0002): payloads never leave the device.
  private let diagnostics = DiagnosticsCollector()

  init() {
    diagnostics.start()
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
