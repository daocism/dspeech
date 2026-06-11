import Foundation

// why: AVAudioSession is process-global; four independent capture clients (live
// transcription, callsign dictation, voice enrollment, input level meter) can otherwise
// activate/deactivate it under each other — dictation stopping would tear the session out
// from under a live cockpit transcription. This arbiter models exclusive ownership of the
// process-global resource, so it is itself process-global by design (`shared`); tests
// construct isolated instances.
@MainActor
final class AudioCaptureArbiter {
  enum Client: String, CaseIterable, Sendable {
    case liveTranscription
    case callsignDictation
    case voiceEnrollment
    case inputLevelMeter
  }

  static let shared = AudioCaptureArbiter()

  private(set) var activeClient: Client?

  init() {}

  // why: live transcription is the product's core capability — it may preempt the level
  // meter (a cosmetic surface), but secondary recorders may never preempt anything.
  func acquire(_ client: Client) -> Bool {
    switch activeClient {
    case .none:
      activeClient = client
      DspeechLog.audioSession.info(
        "audio capture acquired client=\(client.rawValue, privacy: .public)"
      )
      return true
    case .some(let current) where current == client:
      DspeechLog.audioSession.info(
        "audio capture acquire reused client=\(client.rawValue, privacy: .public)"
      )
      return true
    case .some(.inputLevelMeter) where client == .liveTranscription:
      DspeechLog.audioSession.info(
        "audio capture preempted previous=\(Client.inputLevelMeter.rawValue, privacy: .public) client=\(client.rawValue, privacy: .public)"
      )
      activeClient = client
      return true
    case .some(let current):
      DspeechLog.audioSession.info(
        "audio capture acquire refused client=\(client.rawValue, privacy: .public) active=\(current.rawValue, privacy: .public)"
      )
      return false
    }
  }

  // why: only the current holder releases ownership; a stale release from a preempted or
  // already-stopped client must not free (or deactivate the session under) the new holder.
  @discardableResult
  func release(_ client: Client) -> Bool {
    guard activeClient == client else {
      let active = activeClient?.rawValue ?? "none"
      DspeechLog.audioSession.info(
        "audio capture release refused client=\(client.rawValue, privacy: .public) active=\(active, privacy: .public)"
      )
      return false
    }
    activeClient = nil
    DspeechLog.audioSession.info(
      "audio capture released client=\(client.rawValue, privacy: .public)"
    )
    return true
  }

  var isLiveCaptureActive: Bool { activeClient == .liveTranscription }
}
