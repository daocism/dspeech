// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DspeechReplayKit",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "dspeech-replay", targets: ["DspeechReplayKit"])
  ],
  targets: [
    .executableTarget(
      name: "DspeechReplayKit",
      path: "Sources/DspeechReplayKit"
    )
  ]
)
