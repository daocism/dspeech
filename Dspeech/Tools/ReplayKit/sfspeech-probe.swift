import Foundation

struct ProbeResult: Codable {
  let fixture: String
  let transcript: String?
  let error: String?
  let requiresOnDeviceRecognition: Bool
  let usedServerFallback: Bool
}

struct ProbeEnvelope: Codable {
  let locale: String
  let firstAttemptRequiresOnDeviceRecognition: Bool
  let allowsServerFallback: Bool
  let authorizationStatus: String
  let recognizerAvailable: Bool
  let supportsOnDeviceRecognition: Bool
  let results: [ProbeResult]
}

enum ProbeError: Error, CustomStringConvertible {
  case invalidArguments
  case commandFailed(String, Int32)
  case missingRepoRoot
  case missingAppBundle(String)
  case missingSimulator
  case missingContainer
  case missingResult(String)
  case emptyTranscript(String)

  var description: String {
    switch self {
    case .invalidArguments:
      return "Usage: xcrun swift Dspeech/Tools/ReplayKit/sfspeech-probe.swift <wav> [<wav> ...]"
    case .commandFailed(let command, let status):
      return "Command failed (\(status)): \(command)"
    case .missingRepoRoot:
      return "Unable to locate Dspeech.xcodeproj from the current directory."
    case .missingAppBundle(let path):
      return "Built Dspeech.app was not found at \(path)"
    case .missingSimulator:
      return "No available iPhone 17 Pro simulator was found."
    case .missingContainer:
      return "Unable to locate Dspeech app data container in the simulator."
    case .missingResult(let path):
      return "Simulator probe did not write \(path)"
    case .emptyTranscript(let fixture):
      return "Speech probe returned an empty transcript for \(fixture)"
    }
  }
}

struct CommandResult {
  let stdout: String
  let stderr: String
  let status: Int32
}

let bundleID = "com.dspeech.app"
let developerDir = "/Applications/Xcode.app/Contents/Developer"
let xcrunPath = "/usr/bin/xcrun"
let derivedDataPath = "/tmp/dspeech-sfspeech-probe-derived"
let resultFileName = "sfspeech-probe-result.json"

func run(
  _ executable: String,
  _ arguments: [String],
  allowFailure: Bool = false,
  captureOutput: Bool = true
) throws -> CommandResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": developerDir])
  { _, new in new }

  let stdoutPipe = captureOutput ? Pipe() : nil
  let stderrPipe = captureOutput ? Pipe() : nil
  process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
  process.standardError = stderrPipe ?? FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()

  let stdout =
    stdoutPipe.flatMap {
      String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } ?? ""
  let standardError =
    stderrPipe.flatMap {
      String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } ?? ""
  if process.terminationStatus != 0 && !allowFailure {
    let rendered = ([executable] + arguments).joined(separator: " ")
    if !stdout.isEmpty { fputs(stdout, stderr) }
    if !standardError.isEmpty { fputs(standardError, stderr) }
    throw ProbeError.commandFailed(rendered, process.terminationStatus)
  }
  return CommandResult(stdout: stdout, stderr: standardError, status: process.terminationStatus)
}

func repoRoot() throws -> URL {
  var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  while true {
    if FileManager.default.fileExists(
      atPath: cursor.appendingPathComponent("Dspeech.xcodeproj").path)
    {
      return cursor
    }
    let parent = cursor.deletingLastPathComponent()
    if parent.path == cursor.path { throw ProbeError.missingRepoRoot }
    cursor = parent
  }
}

func selectedSimulatorUDID() throws -> String {
  if let udid = ProcessInfo.processInfo.environment["DSPEECH_PROBE_UDID"], !udid.isEmpty {
    return udid
  }
  let result = try run(
    xcrunPath,
    ["simctl", "list", "devices", "available"]
  )
  var inIOS26Runtime = false
  for line in result.stdout.components(separatedBy: .newlines) {
    if line.hasPrefix("-- iOS 26") {
      inIOS26Runtime = true
      continue
    }
    if line.hasPrefix("-- ") {
      inIOS26Runtime = false
      continue
    }
    guard inIOS26Runtime, line.contains("iPhone 17 Pro (") else { continue }
    let parts = line.components(separatedBy: CharacterSet(charactersIn: "()"))
    if parts.count >= 2 { return parts[1] }
  }
  throw ProbeError.missingSimulator
}

func buildApp(root: URL, udid: String) throws -> URL {
  _ = try run(
    "\(developerDir)/usr/bin/xcodebuild",
    [
      "-project", root.appendingPathComponent("Dspeech.xcodeproj").path,
      "-scheme", "Dspeech",
      "-destination", "platform=iOS Simulator,id=\(udid)",
      "-derivedDataPath", derivedDataPath,
      "CODE_SIGNING_ALLOWED=NO",
      "build",
    ],
    captureOutput: false
  )
  let app = URL(fileURLWithPath: derivedDataPath, isDirectory: true)
    .appendingPathComponent("Build/Products/Debug-iphonesimulator/Dspeech.app")
  guard FileManager.default.fileExists(atPath: app.path) else {
    throw ProbeError.missingAppBundle(app.path)
  }
  return app
}

func seedTCC(udid: String) throws {
  let db = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    .appendingPathComponent(udid)
    .appendingPathComponent("data/Library/TCC/TCC.db")
  let now = Int(Date().timeIntervalSince1970)
  let sql = """
    INSERT OR REPLACE INTO access (
      service, client, client_type, auth_value, auth_reason, auth_version, csreq,
      policy_id, indirect_object_identifier_type, indirect_object_identifier,
      indirect_object_code_identity, flags, last_modified, pid, pid_version,
      boot_uuid, last_reminded
    ) VALUES
      ('kTCCServiceSpeechRecognition', '\(bundleID)', 0, 2, 3, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, \(now), 0, 0, 'UNUSED', 0),
      ('kTCCServiceMicrophone', '\(bundleID)', 0, 2, 3, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, \(now), 0, 0, 'UNUSED', 0);
    """
  _ = try run("/usr/bin/sqlite3", [db.path, sql])
}

func installAndAuthorize(app: URL, udid: String) throws {
  _ = try run(xcrunPath, ["simctl", "shutdown", udid], allowFailure: true)
  _ = try run(xcrunPath, ["simctl", "boot", udid], allowFailure: true)
  _ = try run(xcrunPath, ["simctl", "bootstatus", udid, "-b"])
  _ = try run(xcrunPath, ["simctl", "uninstall", udid, bundleID], allowFailure: true)
  _ = try run(xcrunPath, ["simctl", "install", udid, app.path])
  _ = try run(xcrunPath, ["simctl", "shutdown", udid])
  _ = try run(
    xcrunPath,
    ["simctl", "privacy", udid, "grant", "microphone", bundleID],
    allowFailure: true
  )
  let speechGrant = try run(
    xcrunPath,
    ["simctl", "privacy", udid, "grant", "speech-recognition", bundleID],
    allowFailure: true
  )
  if speechGrant.status != 0 {
    try seedTCC(udid: udid)
  }
  _ = try run(xcrunPath, ["simctl", "boot", udid], allowFailure: true)
  _ = try run(xcrunPath, ["simctl", "bootstatus", udid, "-b"])
  Thread.sleep(forTimeInterval: 2.0)
}

func prepareFixtures(paths: [String], udid: String) throws -> (container: URL, appPaths: [String]) {
  var containerResult: CommandResult?
  for attempt in 1...6 {
    let result = try run(
      xcrunPath,
      ["simctl", "get_app_container", udid, bundleID, "data"],
      allowFailure: true
    )
    if result.status == 0 {
      containerResult = result
      break
    }
    containerResult = result
    Thread.sleep(forTimeInterval: Double(attempt))
  }
  guard let containerResult, containerResult.status == 0 else {
    throw ProbeError.missingContainer
  }
  let containerPath = containerResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !containerPath.isEmpty else { throw ProbeError.missingContainer }
  let container = URL(fileURLWithPath: containerPath, isDirectory: true)
  let documents = container.appendingPathComponent("Documents", isDirectory: true)
  try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
  let resultURL = documents.appendingPathComponent(resultFileName)
  try? FileManager.default.removeItem(at: resultURL)

  let appPaths = try paths.map { path -> String in
    let source = URL(fileURLWithPath: path)
    let destination = documents.appendingPathComponent(source.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    return destination.path
  }
  return (container, appPaths)
}

func launchProbe(udid: String, appPaths: [String], container: URL) throws -> ProbeEnvelope {
  _ = try run(xcrunPath, ["simctl", "terminate", udid, bundleID], allowFailure: true)
  var lastLaunch: CommandResult?
  for attempt in 1...6 {
    let launch = try run(
      xcrunPath,
      ["simctl", "launch", udid, bundleID, "--dspeech-sfspeech-probe"] + appPaths,
      allowFailure: true
    )
    if launch.status == 0 {
      lastLaunch = launch
      break
    }
    lastLaunch = launch
    Thread.sleep(forTimeInterval: Double(attempt))
  }
  if let lastLaunch, lastLaunch.status != 0 {
    if !lastLaunch.stdout.isEmpty { fputs(lastLaunch.stdout, stderr) }
    if !lastLaunch.stderr.isEmpty { fputs(lastLaunch.stderr, stderr) }
    throw ProbeError.commandFailed("simctl launch \(bundleID)", lastLaunch.status)
  }
  let resultURL = container.appendingPathComponent("Documents").appendingPathComponent(
    resultFileName)
  for _ in 0..<240 {
    if FileManager.default.fileExists(atPath: resultURL.path) {
      let data = try Data(contentsOf: resultURL)
      return try JSONDecoder().decode(ProbeEnvelope.self, from: data)
    }
    Thread.sleep(forTimeInterval: 0.5)
  }
  throw ProbeError.missingResult(resultURL.path)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard !arguments.isEmpty else { throw ProbeError.invalidArguments }

  let root = try repoRoot()
  let udid = try selectedSimulatorUDID()
  let app = try buildApp(root: root, udid: udid)
  try installAndAuthorize(app: app, udid: udid)
  let prepared = try prepareFixtures(paths: arguments, udid: udid)
  let envelope = try launchProbe(
    udid: udid, appPaths: prepared.appPaths, container: prepared.container)

  let data = try JSONEncoder().encode(envelope)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))

  let failingResult = envelope.results.first { result in
    result.error != nil
      || (result.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  if let failingResult {
    if let error = failingResult.error {
      fputs("\(failingResult.fixture): \(error)\n", stderr)
      exit(1)
    }
    throw ProbeError.emptyTranscript(failingResult.fixture)
  }
  exit(0)
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
