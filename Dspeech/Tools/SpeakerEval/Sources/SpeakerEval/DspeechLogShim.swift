import os

// why: the vendored Core/VoiceFilter sources (FluidAudioSpeakerIdentifier) log via
// DspeechLog.modelPack. The app defines DspeechLog in its own target; this host-eval tool
// provides the same shape so the REAL shipping source compiles and runs unchanged here.
enum DspeechLog {
  static let modelPack = Logger(subsystem: "com.dspeech.speakereval", category: "model-pack")
}
