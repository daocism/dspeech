import Testing

@testable import Dspeech

// Branch checklist for AppleSpeechEngineSupport (SUT Dspeech/Core/ASR/AppleSpeechEngineSupport.swift).
// The engine-lifecycle suite already pins terminationDecision, shouldResetRestartGuard, the main
// restart-guard cases, the startupGate retry/fail cases, replay-tail trimming and restartDecision's
// engine-died fail. This suite covers the value-type branches those tests do NOT reach directly.
//
// ASRFailure.isBenignRestart: 1110 -> true; 203 with "retry" (case-insensitive) -> true; 203 w/o
//   "retry" -> false; other kAF code -> false; SFSpeech duration-limit/request-timed-out/
//   request-timeout/timed-out (case-insensitive) -> true; SFSpeech other message -> false; other
//   domain -> false.
// RecognizerCapabilityRead.isReady: (skip||available) && (!require||supports) truth table.
// startupGateDecision: recognizer-unavailable branch; skipPermission bypasses availability;
//   secondRead nil fallback to firstRead; firstRead-ready happy path; requireOnDeviceModel false.
// restartDecision: not-listening -> ignore; listening+running -> restart.
// sourceLanguageCode: region-stripped two-letter; fallback when no language subtag.
// interimRestartSegment: confidence 0, isInterimRestartCommit, liveATC source, derived language.
// PendingRecognitionPartial: partial sets; final+segment clears; empty final keeps; final partial
//   keeps; non-final segment leaves text; takeTrimmedText trims+clears+nil-on-empty; whitespace ->
//   nil; clear resets.
// AudioReplayTail guards: zero sampleCount, zero sampleRate, zero maxBufferCount, zero
//   maxDurationSeconds, negative-init clamp, removeAll.
// ASRRestartLoopGuard boundary: exactly-at-window kept, one-past dropped; maxRestartCount 0 fails
//   on first restart; recordResult on empty state then allow.
@MainActor
struct AppleSpeechEngineSupportTests {

  // MARK: - ASRFailure.isBenignRestart

  @Test func noSpeechTimeoutIsBenign() {
    #expect(
      ASRFailure(domain: "kAFAssistantErrorDomain", code: 1110, message: "No speech")
        .isBenignRestart)
  }

  @Test func assistantRetryIsBenignCaseInsensitive() {
    #expect(
      ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Please RETRY the asset")
        .isBenignRestart)
  }

  @Test func assistant203WithoutRetryKeywordIsNotBenign() {
    #expect(
      !ASRFailure(domain: "kAFAssistantErrorDomain", code: 203, message: "Asset failed")
        .isBenignRestart)
  }

  @Test func unknownAssistantCodeIsNotBenign() {
    #expect(
      !ASRFailure(domain: "kAFAssistantErrorDomain", code: 300, message: "retry")
        .isBenignRestart)
  }

  @Test(arguments: [
    "Recognition duration limit was reached.",
    "The request timed out.",
    "request-timeout",
    "It timed out",
    "TIMED OUT waiting",
  ])
  func speechErrorTransientMessagesAreBenign(message: String) {
    #expect(ASRFailure(domain: "SFSpeechErrorDomain", code: 1, message: message).isBenignRestart)
  }

  @Test func speechErrorOtherMessageIsNotBenign() {
    #expect(
      !ASRFailure(domain: "SFSpeechErrorDomain", code: 1, message: "no speech authorization")
        .isBenignRestart)
  }

  @Test func unrelatedDomainIsNotBenign() {
    #expect(
      !ASRFailure(domain: "kLSRErrorDomain", code: 300, message: "timed out").isBenignRestart)
  }

  // MARK: - RecognizerCapabilityRead.isReady

  @Test func readyWhenSkippingPermissionAndModelNotRequired() {
    let read = RecognizerCapabilityRead(isAvailable: false, supportsOnDeviceRecognition: false)
    #expect(read.isReady(requireOnDeviceModel: false, skipPermissionRequests: true))
  }

  @Test func readyWhenAvailableAndModelPresentAndRequired() {
    let read = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: true)
    #expect(read.isReady(requireOnDeviceModel: true, skipPermissionRequests: false))
  }

  @Test func notReadyWhenUnavailableAndPermissionRequired() {
    let read = RecognizerCapabilityRead(isAvailable: false, supportsOnDeviceRecognition: true)
    #expect(!read.isReady(requireOnDeviceModel: false, skipPermissionRequests: false))
  }

  @Test func notReadyWhenModelRequiredButUnsupported() {
    let read = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)
    #expect(!read.isReady(requireOnDeviceModel: true, skipPermissionRequests: false))
  }

  // MARK: - startupGateDecision

  @Test func startupGateFailsUnavailableWhenPermissionRequired() {
    let unavailable = RecognizerCapabilityRead(
      isAvailable: false, supportsOnDeviceRecognition: true)
    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: unavailable,
        secondRead: unavailable,
        requireOnDeviceModel: false,
        skipPermissionRequests: false
      ) == .fail("recognizer-unavailable"))
  }

  @Test func startupGateSkipsAvailabilityCheckWhenPermissionRequestsSkipped() {
    let unavailable = RecognizerCapabilityRead(
      isAvailable: false, supportsOnDeviceRecognition: true)
    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: unavailable,
        secondRead: nil,
        requireOnDeviceModel: true,
        skipPermissionRequests: true
      ) == .ready)
  }

  @Test func startupGateFallsBackToFirstReadWhenSecondReadIsNil() {
    let notReady = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)
    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: notReady,
        secondRead: nil,
        requireOnDeviceModel: true,
        skipPermissionRequests: false
      ) == .fail("on-device-model-missing"))
  }

  @Test func startupGateReadyOnFirstReadWithoutConsultingSecond() {
    let ready = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: true)
    let poisoned = RecognizerCapabilityRead(isAvailable: false, supportsOnDeviceRecognition: false)
    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: ready,
        secondRead: poisoned,
        requireOnDeviceModel: true,
        skipPermissionRequests: false
      ) == .ready)
  }

  @Test func startupGateReadyWhenModelNotRequiredAndAvailable() {
    let noModel = RecognizerCapabilityRead(isAvailable: true, supportsOnDeviceRecognition: false)
    #expect(
      AppleSpeechLiveTranscriptionEngine.startupGateDecision(
        firstRead: noModel,
        secondRead: nil,
        requireOnDeviceModel: false,
        skipPermissionRequests: false
      ) == .ready)
  }

  // MARK: - restartDecision

  @Test func restartDecisionIgnoredWhenNotListening() {
    #expect(
      AppleSpeechLiveTranscriptionEngine.restartDecision(
        isListening: false, isAudioEngineRunning: true) == .ignore)
  }

  @Test func restartDecisionRestartsWhenListeningEngineIsRunning() {
    #expect(
      AppleSpeechLiveTranscriptionEngine.restartDecision(
        isListening: true, isAudioEngineRunning: true) == .restart)
  }

  // MARK: - sourceLanguageCode

  @Test func sourceLanguageCodeStripsRegionToLanguageSubtag() {
    #expect(AppleSpeechLiveTranscriptionEngine.sourceLanguageCode(for: "en-US") == "en")
  }

  @Test func sourceLanguageCodeFallsBackToIdentifierWhenNoLanguageSubtag() {
    #expect(AppleSpeechLiveTranscriptionEngine.sourceLanguageCode(for: "") == "")
  }

  // MARK: - interimRestartSegment

  @Test func interimRestartSegmentUsesRestartCommitDefaults() {
    let segment = AppleSpeechLiveTranscriptionEngine.interimRestartSegment(
      text: "cleared to land", localeIdentifier: "fr-FR")
    #expect(segment.text == "cleared to land")
    #expect(segment.confidence == 0)
    #expect(segment.isInterimRestartCommit)
    #expect(segment.source == .liveATC)
    #expect(segment.sourceLanguageCode == "fr")
  }

  // MARK: - PendingRecognitionPartial

  @Test func partialEventSetsPendingText() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("november one"), isFinal: false)
    #expect(partial.takeTrimmedText() == "november one")
  }

  @Test func finalSegmentClearsPendingText() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("november one"), isFinal: false)
    partial.record(event: .segment(Self.segment("november one two"), speaker: nil), isFinal: true)
    #expect(partial.takeTrimmedText() == nil)
  }

  @Test func emptyFinalKeepsLastPartial() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("five mike alpha"), isFinal: false)
    partial.record(event: nil, isFinal: true)
    #expect(partial.takeTrimmedText() == "five mike alpha")
  }

  @Test func finalPartialEventKeepsTextWhenNotASegment() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("descend flight level"), isFinal: true)
    #expect(partial.takeTrimmedText() == "descend flight level")
  }

  @Test func nonFinalSegmentLeavesPendingTextUntouched() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("hold short"), isFinal: false)
    partial.record(event: .segment(Self.segment("ignored"), speaker: nil), isFinal: false)
    #expect(partial.takeTrimmedText() == "hold short")
  }

  @Test func takeTrimmedTextTrimsAndClears() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("  runway two seven  "), isFinal: false)
    #expect(partial.takeTrimmedText() == "runway two seven")
    #expect(partial.takeTrimmedText() == nil)
  }

  @Test func takeTrimmedTextReturnsNilForWhitespaceOnly() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial(" \n\t "), isFinal: false)
    #expect(partial.takeTrimmedText() == nil)
  }

  @Test func clearDiscardsPendingText() {
    var partial = PendingRecognitionPartial()
    partial.record(event: .partial("taxi to gate"), isFinal: false)
    partial.clear()
    #expect(partial.takeTrimmedText() == nil)
  }

  // MARK: - AudioReplayTail guards

  @Test func replayTailIgnoresZeroSampleCount() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 10, maxBufferCount: 4)
    tail.append(1, sampleCount: 0, sampleRate: 16_000)
    #expect(tail.buffers.isEmpty)
  }

  @Test func replayTailIgnoresZeroSampleRate() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 10, maxBufferCount: 4)
    tail.append(1, sampleCount: 1_600, sampleRate: 0)
    #expect(tail.buffers.isEmpty)
  }

  @Test func replayTailWithZeroBufferBoundNeverStores() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 10, maxBufferCount: 0)
    tail.append(1, sampleCount: 1_600, sampleRate: 16_000)
    #expect(tail.buffers.isEmpty)
  }

  @Test func replayTailWithZeroDurationBoundNeverStores() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 0, maxBufferCount: 4)
    tail.append(1, sampleCount: 1_600, sampleRate: 16_000)
    #expect(tail.buffers.isEmpty)
  }

  @Test func replayTailClampsNegativeBoundsToNoStorage() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: -5, maxBufferCount: -3)
    tail.append(1, sampleCount: 1_600, sampleRate: 16_000)
    #expect(tail.buffers.isEmpty)
  }

  @Test func replayTailRemoveAllEmptiesStoredBuffers() {
    var tail = AudioReplayTail<Int>(maxDurationSeconds: 10, maxBufferCount: 4)
    tail.append(1, sampleCount: 1_600, sampleRate: 16_000)
    tail.append(2, sampleCount: 1_600, sampleRate: 16_000)
    tail.removeAll()
    #expect(tail.buffers.isEmpty)
  }

  // MARK: - ASRRestartLoopGuard window boundary

  @Test func restartGuardKeepsRestartExactlyAtWindowEdge() {
    let start = ContinuousClock().now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 1, window: .seconds(10))
    #expect(guardState.recordRestart(now: start) == .allow)
    // The earlier restart is exactly `window` old (10s -> 10s), so it is still counted -> 2 > 1.
    #expect(
      guardState.recordRestart(now: start.advanced(by: .seconds(10))) == .fail("asr-restart-loop"))
  }

  @Test func restartGuardDropsRestartJustPastWindowEdge() {
    let start = ContinuousClock().now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 1, window: .seconds(10))
    #expect(guardState.recordRestart(now: start) == .allow)
    #expect(
      guardState.recordRestart(now: start.advanced(by: .milliseconds(10_001))) == .allow)
  }

  @Test func restartGuardWithZeroCeilingFailsOnFirstRestart() {
    let start = ContinuousClock().now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 0, window: .seconds(10))
    #expect(guardState.recordRestart(now: start) == .fail("asr-restart-loop"))
  }

  @Test func restartGuardRecordResultOnEmptyStateThenAllows() {
    let start = ContinuousClock().now
    var guardState = ASRRestartLoopGuard(maxRestartCount: 1, window: .seconds(10))
    guardState.recordResult()
    #expect(guardState.recordRestart(now: start) == .allow)
  }

  private static func segment(_ text: String) -> TranscriptSegment {
    TranscriptSegment(text: text, confidence: 0.9, sourceLanguageCode: "en", source: .liveATC)
  }
}
