# Release Checklist

## Binary Preflight

- [ ] privacy manifest present at `Dspeech/PrivacyInfo.xcprivacy` and bundled in the app target.
- [ ] export compliance answer set in App Store Connect after reviewing the actual cryptography surface.
- [ ] screenshots captured for App Store listing under `tmp/app-store-screenshots/`.
- [ ] listing-en copy is present.
- [ ] locales present for every App Store listing locale planned for this release.
- [ ] version bumped in `MARKETING_VERSION`.
- [ ] build monotonic in `CURRENT_PROJECT_VERSION`.
- [ ] unsigned archive can be produced at `tmp/release/Dspeech.xcarchive`.
- [ ] signed archive validates in Xcode Organizer.
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
