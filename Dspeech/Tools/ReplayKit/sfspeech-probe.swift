import Foundation
import Speech

struct ProbeResult: Encodable {
  let fixture: String
  let transcript: String?
  let error: String?
}

struct ProbeEnvelope: Encodable {
  let locale: String
  let requiresOnDeviceRecognition: Bool
  let authorizationStatus: String
  let recognizerAvailable: Bool
  let supportsOnDeviceRecognition: Bool
  let results: [ProbeResult]
}

enum ProbeError: Error, CustomStringConvertible {
  case invalidArguments
  case missingRecognizer(String)
  case unsupportedOnDeviceRecognition(String)
  case unauthorized(String)
  case recognition(String)

  var description: String {
    switch self {
    case .invalidArguments:
      return "Usage: xcrun swift Dspeech/Tools/ReplayKit/sfspeech-probe.swift <wav> [<wav> ...]"
    case .missingRecognizer(let locale):
      return "SFSpeechRecognizer is unavailable for locale \(locale)"
    case .unsupportedOnDeviceRecognition(let locale):
      return "SFSpeechRecognizer does not support on-device recognition for locale \(locale)"
    case .unauthorized(let status):
      return "Speech authorization did not resolve to authorized: \(status)"
    case .recognition(let message):
      return message
    }
  }
}

func authorizationStatusName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
  switch status {
  case .notDetermined: return "notDetermined"
  case .denied: return "denied"
  case .restricted: return "restricted"
  case .authorized: return "authorized"
  @unknown default: return "unknown(\(status.rawValue))"
  }
}

func requestAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
  let semaphore = DispatchSemaphore(value: 0)
  final class Box: @unchecked Sendable {
    var status: SFSpeechRecognizerAuthorizationStatus = .notDetermined
  }
  let box = Box()
  SFSpeechRecognizer.requestAuthorization { status in
    box.status = status
    semaphore.signal()
  }
  _ = semaphore.wait(timeout: .now() + 3600)
  return box.status
}

func transcribe(url: URL, recognizer: SFSpeechRecognizer) -> Result<String, Error> {
  let request = SFSpeechURLRecognitionRequest(url: url)
  request.requiresOnDeviceRecognition = true
  request.shouldReportPartialResults = false
  request.taskHint = .dictation

  let semaphore = DispatchSemaphore(value: 0)
  final class Box: @unchecked Sendable {
    var transcript: String?
    var error: Error?
  }
  let box = Box()
  let task = recognizer.recognitionTask(with: request) { result, error in
    if let result {
      box.transcript = result.bestTranscription.formattedString
      if result.isFinal {
        semaphore.signal()
      }
    }
    if let error {
      box.error = error
      semaphore.signal()
    }
  }
  let waitResult = semaphore.wait(timeout: .now() + 3600)
  if waitResult == .timedOut {
    task.cancel()
    return .failure(ProbeError.recognition("Recognition timed out for \(url.lastPathComponent)"))
  }
  if let error = box.error {
    return .failure(error)
  }
  return .success(box.transcript ?? "")
}

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
  fputs("\(ProbeError.invalidArguments)\n", stderr)
  exit(64)
}

let localeIdentifier = "en-US"
let locale = Locale(identifier: localeIdentifier)
guard let recognizer = SFSpeechRecognizer(locale: locale) else {
  fputs("\(ProbeError.missingRecognizer(localeIdentifier))\n", stderr)
  exit(69)
}

let status = requestAuthorization()
let statusName = authorizationStatusName(status)
guard status == .authorized else {
  let envelope = ProbeEnvelope(
    locale: localeIdentifier,
    requiresOnDeviceRecognition: true,
    authorizationStatus: statusName,
    recognizerAvailable: recognizer.isAvailable,
    supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
    results: arguments.map {
      ProbeResult(
        fixture: URL(fileURLWithPath: String($0)).lastPathComponent, transcript: nil,
        error: ProbeError.unauthorized(statusName).description)
    }
  )
  let data = try JSONEncoder().encode(envelope)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(77)
}

guard recognizer.supportsOnDeviceRecognition else {
  fputs("\(ProbeError.unsupportedOnDeviceRecognition(localeIdentifier))\n", stderr)
  exit(78)
}

let results = arguments.map { path in
  let url = URL(fileURLWithPath: String(path))
  switch transcribe(url: url, recognizer: recognizer) {
  case .success(let transcript):
    return ProbeResult(fixture: url.lastPathComponent, transcript: transcript, error: nil)
  case .failure(let error):
    return ProbeResult(
      fixture: url.lastPathComponent, transcript: nil, error: String(describing: error))
  }
}

let envelope = ProbeEnvelope(
  locale: localeIdentifier,
  requiresOnDeviceRecognition: true,
  authorizationStatus: statusName,
  recognizerAvailable: recognizer.isAvailable,
  supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
  results: results
)
let data = try JSONEncoder().encode(envelope)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
exit(results.contains { $0.error != nil } ? 1 : 0)
