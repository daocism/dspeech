# Dspeech iOS

Dspeech is an iOS-first aviation communication companion:

Domain: `dspeech.com`.

Dspeech is built for receive-only cockpit/intercom audio capture, real-time ATC transcription, and optional translation while keeping the original transcript primary.

## Current bootstrap

- Platform: iOS 26+ prototype, built on macOS 26 / Xcode 26.
- UI: SwiftUI, large landscape-first transcript surface.
- Language: Swift 6 with strict concurrency enabled.
- Tests: Swift Testing for domain logic, XCTest UI smoke test for app launch.
- Architecture: app shell + protocol-first audio / ASR pipeline stubs, so WhisperKit/Core ML / Apple Speech / cloud fallback can be benchmarked without rewriting UI.

## Local commands

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Dspeech.xcodeproj -scheme Dspeech \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  CODE_SIGNING_ALLOWED=NO build test
```

If `xcodebuild` says only CommandLineTools are active, keep `DEVELOPER_DIR` as above or set Xcode globally:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Next implementation slices

1. Add real audio session/capture spike with wired USB-C class-compliant audio interface.
2. Add replay-file ingestion so ASR benchmarks are reproducible without aircraft hardware.
3. Add on-device ASR adapters: Apple Speech baseline + WhisperKit/Core ML candidate.
4. Add transcript confidence/verification UX and aviation entity protection.
