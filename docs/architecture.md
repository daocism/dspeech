# Dspeech architecture sketch

## North star

A pilot-friendly, receive-only assistant that turns noisy ATC/intercom audio into large, readable text with latency low enough to be useful in cockpit workflows.

## 2026 expert baseline

- Native iOS first: SwiftUI app target, Swift 6 strict concurrency, Xcode 26 simulator/device workflows.
- Local-first by default: no cockpit audio leaves the device unless the user explicitly enables cloud fallback.
- Protocol-first ASR boundary: UI and aviation-domain rules do not depend directly on one vendor/model.
- Reproducible evaluation: every ASR model is tested against the same replay corpus and scoring scripts.
- Hardware truth first: built-in mic is demo-only; wired intercom/radio capture is the validation path.

## Main modules

- `App/`: SwiftUI composition and view models.
- `Core/Models/`: transcript/domain value types.
- `Core/Audio/`: audio capture contracts and future AVAudioEngine implementation.
- `Core/ASR/`: speech recognition contracts and future Apple Speech / WhisperKit / cloud adapters.

## Decisions pending

- Minimum production iOS version after first hardware spike.
- Exact ASR model shortlist after replay-corpus benchmark.
- Translation stack and offline pack policy.
