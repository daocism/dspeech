import Foundation
import Testing

@testable import Dspeech

// Branch checklist for OnDeviceLocaleAvailability (SUT Dspeech/Core/Settings/OnDeviceLocaleAvailability.swift).
// The pure functional core is exercised here; SystemOnDeviceLocaleAvailability is the imperative
// shell over the real Speech stack and is not unit-testable deterministically.
//
// speechRecognizerCapableLocales: onDevice empty -> []; shared locales kept; disjoint -> [];
//   matching is by BCP-47 (region/script decoration differences still match).
// capableLocales: onDevice empty -> []; intersection non-empty -> intersection; intersection empty
//   -> falls back to the on-device set.
// OnDeviceDownloadPoller.isDownloaded: immediate true (attempt 0); true on a later attempt;
//   never true -> false with attempts-1 sleeps; attempts == 1 performs no sleep; a throwing sleep
//   propagates.
struct OnDeviceLocaleAvailabilityTests {

  // MARK: - speechRecognizerCapableLocales

  @Test func strictCapableEmptyWhenOnDeviceSetIsEmpty() {
    let capable = OnDeviceLocaleResolver.speechRecognizerCapableLocales(
      recognizerSupported: [Locale(identifier: "en-US")],
      onDeviceSupported: []
    )
    #expect(capable.isEmpty)
  }

  @Test func strictCapableKeepsLocalesPresentInBothSets() {
    let capable = OnDeviceLocaleResolver.speechRecognizerCapableLocales(
      recognizerSupported: [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")],
      onDeviceSupported: [Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")]
    )
    #expect(capable == [Locale(identifier: "fr-FR")])
  }

  @Test func strictCapableEmptyWhenSetsAreDisjoint() {
    let capable = OnDeviceLocaleResolver.speechRecognizerCapableLocales(
      recognizerSupported: [Locale(identifier: "en-US")],
      onDeviceSupported: [Locale(identifier: "it-IT")]
    )
    #expect(capable.isEmpty)
  }

  @Test func strictCapableMatchesByBcp47IgnoringScriptDecoration() {
    let recognizer = Locale(identifier: "zh-Hant-TW")
    let capable = OnDeviceLocaleResolver.speechRecognizerCapableLocales(
      recognizerSupported: [recognizer],
      onDeviceSupported: [Locale(identifier: "zh-Hant-TW")]
    )
    #expect(capable == [recognizer])
  }

  // MARK: - capableLocales (with fallback)

  @Test func capableEmptyWhenOnDeviceSetIsEmpty() {
    let capable = OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: [Locale(identifier: "en-US")],
      onDeviceSupported: []
    )
    #expect(capable.isEmpty)
  }

  @Test func capableReturnsIntersectionWhenNonEmpty() {
    let capable = OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")],
      onDeviceSupported: [Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")]
    )
    #expect(capable == [Locale(identifier: "fr-FR")])
  }

  @Test func capableFallsBackToOnDeviceSetWhenIntersectionIsEmpty() {
    let onDevice: Set<Locale> = [Locale(identifier: "it-IT"), Locale(identifier: "de-DE")]
    let capable = OnDeviceLocaleResolver.capableLocales(
      recognizerSupported: [Locale(identifier: "en-US")],
      onDeviceSupported: onDevice
    )
    #expect(capable == onDevice)
  }

  // MARK: - OnDeviceDownloadPoller.isDownloaded

  @Test func pollReturnsTrueImmediatelyWithoutSleeping() async throws {
    let sleepCount = CallCounter()
    let result = try await OnDeviceDownloadPoller.isDownloaded(
      attempts: 6,
      supportsOnDeviceRecognition: { true },
      sleep: { sleepCount.increment() }
    )
    #expect(result)
    #expect(sleepCount.value == 0)
  }

  @Test func pollReturnsTrueOnceModelBecomesAvailable() async throws {
    let readiness = CallCounter()
    let result = try await OnDeviceDownloadPoller.isDownloaded(
      attempts: 6,
      supportsOnDeviceRecognition: { readiness.incrementAndReturnValue() >= 3 },
      sleep: {}
    )
    #expect(result)
    #expect(readiness.value == 3)
  }

  @Test func pollReturnsFalseAfterExhaustingAttemptsWithBoundedSleeps() async throws {
    let sleepCount = CallCounter()
    let result = try await OnDeviceDownloadPoller.isDownloaded(
      attempts: 4,
      supportsOnDeviceRecognition: { false },
      sleep: { sleepCount.increment() }
    )
    #expect(result == false)
    #expect(sleepCount.value == 3)
  }

  @Test func pollWithSingleAttemptNeverSleeps() async throws {
    let sleepCount = CallCounter()
    let result = try await OnDeviceDownloadPoller.isDownloaded(
      attempts: 1,
      supportsOnDeviceRecognition: { false },
      sleep: { sleepCount.increment() }
    )
    #expect(result == false)
    #expect(sleepCount.value == 0)
  }

  @Test func pollPropagatesSleepFailure() async {
    await #expect(throws: CancellationError.self) {
      try await OnDeviceDownloadPoller.isDownloaded(
        attempts: 3,
        supportsOnDeviceRecognition: { false },
        sleep: { throw CancellationError() }
      )
    }
  }
}

private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }

  func incrementAndReturnValue() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}
