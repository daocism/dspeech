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
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0")
  ],
  targets: [
    .executableTarget(
      name: "DspeechReplayKit",
      dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift")
      ],
      path: "Sources/DspeechReplayKit"
    )
  ]
)
