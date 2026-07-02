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
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
  ],
  targets: [
    .executableTarget(
      name: "DspeechReplayKit",
      dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      path: "Sources/DspeechReplayKit"
    )
  ]
)
