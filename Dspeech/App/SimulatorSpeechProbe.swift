@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import SwiftUI

struct SimulatorSpeechProbeView: View {
  let fixturePaths: [String]

  var body: some View {
    Text("Dspeech Speech Probe")
      .task {
        await SimulatorSpeechProbe(paths: fixturePaths).run()
      }
  }
}

private struct SimulatorSpeechProbe: Sendable {
  struct Result: Encodable, Sendable {
    let fixture: String
    let transcript: String?
    let error: String?
    let requiresOnDeviceRecognition: Bool
    let usedServerFallback: Bool
  }

  struct Envelope: Encodable, Sendable {
    let locale: String
    let firstAttemptRequiresOnDeviceRecognition: Bool
    let allowsServerFallback: Bool
    let authorizationStatus: String
    let recognizerAvailable: Bool
    let supportsOnDeviceRecognition: Bool
    let results: [Result]
  }

  let paths: [String]
  private let localeIdentifier = "en-US"

  func run() async {
    let locale = Locale(identifier: localeIdentifier)
    let recognizer = SFSpeechRecognizer(locale: locale)
    let status = await Self.requestAuthorization()
    let results: [Result]

    if status == .authorized, let recognizer {
      var recognized: [Result] = []
      recognized.reserveCapacity(paths.count)
      for path in paths {
        let url = URL(fileURLWithPath: path)
        do {
          let recognition = try await Self.transcribeWithSimulatorFallback(
            url: url,
            recognizer: recognizer
          )
          recognized.append(
            Result(
              fixture: url.lastPathComponent,
              transcript: recognition.transcript,
              error: nil,
              requiresOnDeviceRecognition: recognition.requiresOnDeviceRecognition,
              usedServerFallback: recognition.usedServerFallback
            ))
        } catch {
          recognized.append(
            Result(
              fixture: url.lastPathComponent,
              transcript: nil,
              error: String(describing: error),
              requiresOnDeviceRecognition: true,
              usedServerFallback: false
            ))
        }
      }
      results = recognized
    } else {
      let error = "Speech authorization did not resolve to authorized: \(Self.statusName(status))"
      results = paths.map { path in
        Result(
          fixture: URL(fileURLWithPath: path).lastPathComponent,
          transcript: nil,
          error: error,
          requiresOnDeviceRecognition: true,
          usedServerFallback: false
        )
      }
    }

    let envelope = Envelope(
      locale: localeIdentifier,
      firstAttemptRequiresOnDeviceRecognition: true,
      allowsServerFallback: true,
      authorizationStatus: Self.statusName(status),
      recognizerAvailable: recognizer?.isAvailable ?? false,
      supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false,
      results: results
    )
    do {
      let data = try JSONEncoder().encode(envelope)
      try data.write(to: Self.outputURL(), options: .atomic)
    } catch {
      let fallback =
        #"{"locale":"en-US","firstAttemptRequiresOnDeviceRecognition":true,"allowsServerFallback":true,"authorizationStatus":"writeFailed","recognizerAvailable":false,"supportsOnDeviceRecognition":false,"results":[]}"#
      try? Data(fallback.utf8).write(to: Self.outputURL(), options: .atomic)
    }
  }

  private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }

  private static func transcribeWithSimulatorFallback(
    url: URL,
    recognizer: SFSpeechRecognizer
  ) async throws -> ProbeTranscription {
    do {
      let transcript = try await transcribe(
        url: url, recognizer: recognizer, requiresOnDeviceRecognition: true)
      return ProbeTranscription(
        transcript: transcript,
        requiresOnDeviceRecognition: true,
        usedServerFallback: false
      )
    } catch {
      let transcript = try await transcribe(
        url: url, recognizer: recognizer, requiresOnDeviceRecognition: false)
      return ProbeTranscription(
        transcript: transcript,
        requiresOnDeviceRecognition: false,
        usedServerFallback: true
      )
    }
  }

  private static func transcribe(
    url: URL,
    recognizer: SFSpeechRecognizer,
    requiresOnDeviceRecognition: Bool
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
      request.shouldReportPartialResults = false
      request.taskHint = .dictation

      let completion = OneShotSpeechProbeCompletion(continuation: continuation)
      var task: SFSpeechRecognitionTask?
      task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          completion.fail(error)
          task?.cancel()
          return
        }
        guard let result, result.isFinal else { return }
        completion.succeed(result.bestTranscription.formattedString)
      }
      do {
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
          let remaining = AVAudioFrameCount(file.length - file.framePosition)
          let frameCount = min(remaining, 4096)
          guard
            let buffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: frameCount
            )
          else {
            throw CocoaError(.fileReadCorruptFile)
          }
          try file.read(into: buffer, frameCount: frameCount)
          if buffer.frameLength > 0 {
            request.append(buffer)
          }
        }
        request.endAudio()
      } catch {
        task?.cancel()
        completion.fail(error)
      }
    }
  }

  private static func outputURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("sfspeech-probe-result.json")
  }

  private static func statusName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown(\(status.rawValue))"
    }
  }
}

private struct ProbeTranscription: Sendable {
  let transcript: String
  let requiresOnDeviceRecognition: Bool
  let usedServerFallback: Bool
}

private final class OneShotSpeechProbeCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private let continuation: CheckedContinuation<String, any Error>

  init(continuation: CheckedContinuation<String, any Error>) {
    self.continuation = continuation
  }

  func succeed(_ transcript: String) {
    resume { continuation.resume(returning: transcript) }
  }

  func fail(_ error: any Error) {
    resume { continuation.resume(throwing: error) }
  }

  private func resume(_ block: () -> Void) {
    let shouldResume = lock.withLock {
      guard !didResume else { return false }
      didResume = true
      return true
    }
    if shouldResume { block() }
  }
}
