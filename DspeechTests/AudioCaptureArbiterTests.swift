import Testing

@testable import Dspeech

// Branch checklist for AudioCaptureArbiter (see SUT Dspeech/Core/Audio/AudioCaptureArbiter.swift):
// acquire: (1) none -> acquire; (2) same client -> reuse; (3) meter held + live -> preempt +
//   handler; (4) other current -> refuse. Refuse variants: live held + other; meter held +
//   non-live (callsign) tries.
// release: (5) holder -> free; (6) non-holder stale -> refuse and keep current; (7) nil active
//   -> refuse.
// preemption handler: (8) only the meter's handler fires on preemption; (9) ownership already
//   reassigned when handler runs; (10) handler for a never-preempted client never fires; (11)
//   stale release from the preempted meter must not free the new live holder.
// Constructed on isolated instances; `shared` singleton is never touched by tests.
@Suite(.serialized)
@MainActor
struct AudioCaptureArbiterTests {
  @Test func acquireSucceedsWhenNoClientHolds() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))
    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func acquireReusesWhenSameClientAlreadyHolds() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.callsignDictation))
    #expect(arbiter.acquire(.callsignDictation))
    #expect(arbiter.activeClient == .callsignDictation)
  }

  @Test func acquireRefusesWhenAnotherClientHolds() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))
    #expect(arbiter.acquire(.callsignDictation) == false)
    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func acquireRefusesWhenMeterHeldByNonLiveTranscriptionClient() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.inputLevelMeter))
    #expect(arbiter.acquire(.callsignDictation) == false)
    #expect(arbiter.activeClient == .inputLevelMeter)
  }

  @Test func liveTranscriptionPreemptsInputLevelMeter() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.inputLevelMeter))

    #expect(arbiter.acquire(.liveTranscription))

    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func preemptionInvokesOnlyTheMeterTeardownHandler() {
    let arbiter = AudioCaptureArbiter()
    var meterTeardowns = 0
    var liveTeardowns = 0
    arbiter.setPreemptionHandler(for: .inputLevelMeter) { meterTeardowns += 1 }
    arbiter.setPreemptionHandler(for: .liveTranscription) { liveTeardowns += 1 }
    #expect(arbiter.acquire(.inputLevelMeter))

    #expect(arbiter.acquire(.liveTranscription))

    #expect(meterTeardowns == 1)
    #expect(liveTeardowns == 0)
  }

  @Test func preemptionHandlerSeesOwnershipAlreadyReassigned() {
    let arbiter = AudioCaptureArbiter()
    var ownerDuringTeardown: AudioCaptureArbiter.Client?
    arbiter.setPreemptionHandler(for: .inputLevelMeter) {
      ownerDuringTeardown = arbiter.activeClient
    }
    #expect(arbiter.acquire(.inputLevelMeter))

    #expect(arbiter.acquire(.liveTranscription))

    #expect(ownerDuringTeardown == .liveTranscription)
  }

  @Test func meterReuseDoesNotInvokeItsOwnTeardownHandler() {
    let arbiter = AudioCaptureArbiter()
    var meterTeardowns = 0
    arbiter.setPreemptionHandler(for: .inputLevelMeter) { meterTeardowns += 1 }
    #expect(arbiter.acquire(.inputLevelMeter))

    #expect(arbiter.acquire(.inputLevelMeter))

    #expect(meterTeardowns == 0)
    #expect(arbiter.activeClient == .inputLevelMeter)
  }

  @Test func releaseFreesOwnershipWhenCalledByHolder() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.voiceEnrollment))

    #expect(arbiter.release(.voiceEnrollment))

    #expect(arbiter.activeClient == nil)
  }

  @Test func releaseRefusedWhenNoClientHolds() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.release(.liveTranscription) == false)
    #expect(arbiter.activeClient == nil)
  }

  @Test func releaseRefusedFromNonHolderKeepsCurrentOwner() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.liveTranscription))

    #expect(arbiter.release(.callsignDictation) == false)

    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func staleReleaseFromPreemptedMeterDoesNotFreeNewLiveHolder() {
    let arbiter = AudioCaptureArbiter()
    #expect(arbiter.acquire(.inputLevelMeter))
    #expect(arbiter.acquire(.liveTranscription))

    #expect(arbiter.release(.inputLevelMeter) == false)

    #expect(arbiter.activeClient == .liveTranscription)
  }

  @Test func acquireAfterReleaseSucceedsForAnyClient() {
    let arbiter = AudioCaptureArbiter()
    for client in AudioCaptureArbiter.Client.allCases {
      #expect(arbiter.acquire(client))
      #expect(arbiter.activeClient == client)
      #expect(arbiter.release(client))
      #expect(arbiter.activeClient == nil)
    }
  }
}
