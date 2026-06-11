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
      return true
    case .some(let current) where current == client:
      return true
    case .some(.inputLevelMeter) where client == .liveTranscription:
      activeClient = client
      return true
    case .some:
      return false
    }
  }

  // why: only the current holder releases ownership; a stale release from a preempted or
  // already-stopped client must not free (or deactivate the session under) the new holder.
  @discardableResult
  func release(_ client: Client) -> Bool {
    guard activeClient == client else { return false }
    activeClient = nil
    return true
  }

  var isLiveCaptureActive: Bool { activeClient == .liveTranscription }
}
