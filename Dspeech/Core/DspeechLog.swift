import Foundation
import os

// why: field failures (engine death mid-flight, route loss, model-pack install errors)
// must be reconstructable from a sysdiagnose/`log collect` alone — pilots cannot attach
// a debugger. One subsystem, one category per pipeline stage; never interpolate transcript
// text or voiceprint data as public.
enum DspeechLog {
  static let subsystem = "com.dspeech.app"

  static let engine = Logger(subsystem: subsystem, category: "asr-engine")
  static let audioSession = Logger(subsystem: subsystem, category: "audio-session")
  static let routing = Logger(subsystem: subsystem, category: "route-health")
  static let voiceFilter = Logger(subsystem: subsystem, category: "voice-filter")
  static let modelPack = Logger(subsystem: subsystem, category: "model-pack")
  static let translation = Logger(subsystem: subsystem, category: "translation")
  static let persistence = Logger(subsystem: subsystem, category: "persistence")
  static let ui = Logger(subsystem: subsystem, category: "ui")
}
