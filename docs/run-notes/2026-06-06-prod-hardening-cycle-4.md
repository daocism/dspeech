# 2026-06-06 Prod hardening Cycle 4 — release supply-chain/privacy policy gate

## Context

Cycle 3 (`9863942`) made CI green with zero retry flakes:

- GitHub Actions run `27051925329` passed.
- Unit job `79849045034`: `flaky: 0`.
- UI + a11y job `79849045045`: `flaky: 0`.
- Privacy manifest, Swift format/secret scan, and offline replay eval passed.

Post-green critical review still found a production-readiness gap: release artifacts were not yet machine-bound to the exact source/package/privacy state. This cycle adds a source+archive policy gate that does not require Apple Developer account/signing or a physical device.

## Changes

- Added `scripts/release/check-release-policy.py`:
  - validates FluidAudio repo/revision/version/source contract;
  - validates app + SpeakerEval `Package.resolved` pins;
  - validates model-pack source/version and 10-file SHA-256 manifest contract;
  - rejects unexpected production Swift network markers (`URLSession`, `URLRequest`, `.dataTask`, `.uploadTask`, `import Network`, `NWPathMonitor`, raw `http(s)://`);
  - validates source privacy manifest;
  - validates built `.xcarchive` privacy manifest, export-compliance Info.plist key, release binary probe exclusion, and build-stamp hashes.
- Hardened `scripts/release/build-unsigned-archive.sh`:
  - uses hermetic SwiftPM flags:
    - `-disableAutomaticPackageResolution`
    - `-onlyUsePackageVersionsFromResolvedFile`
    - `-skipPackageUpdates`
  - deletes stale build stamp before rebuilding;
  - writes `tmp/release/Dspeech.xcarchive.dspeech-build-stamp.json` after archive creation.
- Hardened `scripts/release/check-release-ready.sh`:
  - runs source policy before archive;
  - runs archive policy against the freshly built archive and stamp.
- Added CI job `release-policy` on `ubuntu-latest`:
  - `python3 -m py_compile scripts/release/check-release-policy.py`
  - `python3 scripts/release/check-release-policy.py --source-only`

## Verification

All commands below were run on `mac24:/Users/andre/projects/dspeech-ios`.

```bash
python3 -m py_compile scripts/release/check-release-policy.py
python3 scripts/release/check-release-policy.py --source-only
# Release policy source checks passed.
```

```bash
bash -n scripts/release/build-unsigned-archive.sh scripts/release/check-release-ready.sh
git diff --check
# exit 0
```

```bash
DSPEECH_ALLOW_DIRTY_RELEASE=1 scripts/release/check-release-ready.sh
# Release policy source checks passed.
# Building fresh unsigned archive for release readiness check...
# Warnings:
#  - dirty source tree allowed by DSPEECH_ALLOW_DIRTY_RELEASE=1 — not a releasable archive
# Release policy source + archive checks passed.
# Signed/TestFlight prerequisites: UNVERIFIED (op unavailable).
# Unsigned release-readiness checks passed (fresh archive built and validated).
```

Negative anti-regression probes:

```bash
# Temporarily adding `URLSession` to SpeakerModelPackInstaller.swift now fails source policy:
# Release policy check failed:
#  - unexpected production network marker 'URLSession' in Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift
# network_green_rc=1
```

```bash
# Temporarily tampering with the archived app binary now fails archive policy:
# Release policy check failed:
#  - build stamp appBinarySHA256 mismatch
# stamp_green_rc=1
```

```bash
# Dirty archive stamps fail without explicit dev override:
python3 scripts/release/check-release-policy.py \
  --archive tmp/release/Dspeech.xcarchive \
  --stamp tmp/release/Dspeech.xcarchive.dspeech-build-stamp.json
# Release policy check failed:
#  - build stamp recorded a dirty source tree; set DSPEECH_ALLOW_DIRTY_RELEASE=1 only for non-release dev verification
# dirty_gate_rc=1
```

Read-only critical review after fixes: `APPROVED`.

## Anti-regression / lessons

- Allowlisting an entire file is too weak for privacy/network gates; allow the intended boundary contract and still reject new raw network APIs in that file.
- A build stamp must bind to the actual archive bytes, not only to source metadata; at minimum hash the app binary, archive Info.plist, and archive privacy manifest.
- Delete stale stamps before archive rebuilds so a failed rebuild cannot leave a convincing old stamp behind.
- Keep source-only policy runnable on Linux CI so supply-chain/privacy drift is caught before the slower macOS archive path.
