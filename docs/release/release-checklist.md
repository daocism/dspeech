# Release Checklist

## Binary Preflight

- [ ] privacy manifest present at `Dspeech/PrivacyInfo.xcprivacy` and bundled in the app target.
- [ ] SDK privacy report reviewed: `xcrun privacyreport` on the fresh unsigned archive
      (FluidAudio + WhisperKit manifests aggregate cleanly, no unexpected domains).
- [ ] export compliance answer set in App Store Connect after reviewing the actual cryptography surface.
- [ ] screenshots captured for App Store listing under `tmp/app-store-screenshots/`.
- [ ] listing-en copy is present.
- [ ] locales present for every App Store listing locale planned for this release
      (all 11 in-app locales fully confirmed in `Localizable.xcstrings` as of 2026-07-02;
      listing drafts exist for all incl. zh-Hans).
- [ ] listing metadata limits green: `python3 scripts/release/check-listing-metadata.py`.
- [ ] app icon variants present: base + dark + tinted in `AppIcon.appiconset`.
- [ ] privacy-policy URL published and set in ASC (draft at `docs/product/privacy-policy.md`;
      publishing is an owner decision).
- [ ] version bumped in `MARKETING_VERSION`.
- [ ] build monotonic in `CURRENT_PROJECT_VERSION`.
- [ ] local gate green: `scripts/local-gate.sh` (format lint, device-arch compile, unit + core UI suites).
- [ ] full a11y sweep green: `DspeechFull` test plan (incl. de + ru AX sweeps).
- [ ] unsigned archive can be produced at `tmp/release/Dspeech.xcarchive`.
- [ ] release policy green against the archive: `check-release-policy.py --archive ...`
      (supply-chain pins: FluidAudio exactVersion, WhisperKit exact, per-file SHA-256 contracts
      for the WhisperKit + Parakeet + speaker-pack installers).
- [ ] signed archive validates in Xcode Organizer (currently blocked on paid Apple Developer
      Program enrollment — free Personal Team `NW2XAS56AW` cannot TestFlight).
- [ ] ASC build received TestFlight processing.
- [ ] internal testers added only after processing completes.

## Policy Gates

- [ ] App Store availability, pricing, and marketing region lists match the
      canonical allowlist in `docs/product/pricing-top20-aviation.md`.
- [ ] no outbound webhook/DM/email release integration.
- [ ] No CI submission automation.
- [ ] No App Store metadata automation.
- [ ] No signing certificate, provisioning profile, ASC API key, `.p8`, JWT, Transporter credential, or exported signing artifact is committed or printed.
- [ ] Secrets are referenced through `op://` items only.
