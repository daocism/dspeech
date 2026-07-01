// swift-tools-version: 6.0
import PackageDescription

// why: host-only evaluation lane for ADR 0008. Runs the real FluidAudio CoreML
// speaker stack (pyannote_segmentation + wespeaker_v2) against recorded ATC fixtures
// to produce diarization + 256-dim embedding evidence off-device. Not part of the iOS
// app target and not wired into per-PR CI (it downloads models from HuggingFace);
// run on demand when validating the speaker backend.
let package = Package(
  name: "SpeakerEval",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4")
  ],
  targets: [
    .executableTarget(
      name: "SpeakerEval",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
    )
  ]
)
