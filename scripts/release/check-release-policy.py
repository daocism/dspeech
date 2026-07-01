#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_FLUIDAUDIO_URL = "https://github.com/FluidInference/FluidAudio.git"
EXPECTED_FLUIDAUDIO_REVISION = "8048812869b0c7c6fa393e564a4fb6f95126ba23"
EXPECTED_FLUIDAUDIO_VERSION = "0.14.7"
EXPECTED_MODEL_SOURCE = "FluidInference/speaker-diarization-coreml"
EXPECTED_MODEL_MANIFEST_COUNT = 10
APP_PACKAGE_RESOLVED = Path("Dspeech.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
SPEAKER_EVAL_PACKAGE_RESOLVED = Path("Dspeech/Tools/SpeakerEval/Package.resolved")
FORBIDDEN_RELEASE_BINARY_MARKERS = [
    b"sfspeech-probe-result",
    b"dspeech-sfspeech-probe",
    b"Dspeech Speech Probe",
]
RELEASE_BINARY_SENTINEL = EXPECTED_MODEL_SOURCE.encode()
PRODUCTION_SOURCE_FORBIDDEN_MARKERS = [
    "URLSession",
    "URLRequest",
    ".dataTask",
    ".uploadTask",
    "import Network",
    "NWPathMonitor",
    "http://",
    "https://",
]
PRODUCTION_SOURCE_NETWORK_ALLOWLIST = {
    Path("Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift"): {"URLSession", "URLRequest"},
    # User-initiated WhisperKit model download (ADR 0011): same explicit-download
    # boundary class as the voice pack — pinned HF revision, local-only afterwards.
    Path("Dspeech/Core/ASR/WhisperKitModelInstaller.swift"): {"URLSession", "URLRequest", "https://"},
    # User-initiated Parakeet EOU model download (English-only third ASR engine): same explicit,
    # pinned-revision Hugging Face download boundary as WhisperKit — local-only inference afterwards.
    Path("Dspeech/Core/ASR/ParakeetModelInstaller.swift"): {"URLSession", "URLRequest", "https://"},
}


class CheckState:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def fail(self, message: str) -> None:
        self.failures.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read_text(path: Path, state: CheckState) -> str:
    if not path.exists():
        state.fail(f"missing file: {rel(path)}")
        return ""
    return path.read_text(encoding="utf-8")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run_git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def git_head() -> str:
    return run_git(["rev-parse", "HEAD"])


def git_dirty() -> bool:
    # Ignore release build output; everything else in-tree must be clean for a real release stamp.
    output = subprocess.check_output(
        ["git", "status", "--porcelain", "--", ".", ":!tmp"], cwd=ROOT, text=True
    )
    return bool(output.strip())


def load_package_pin(path: Path, state: CheckState) -> dict | None:
    if not path.exists():
        state.fail(f"missing Package.resolved: {path}")
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        state.fail(f"invalid Package.resolved JSON: {path}: {exc}")
        return None
    pins = data.get("pins") or []
    for pin in pins:
        if pin.get("identity") == "fluidaudio" or pin.get("location") == EXPECTED_FLUIDAUDIO_URL:
            return pin
    state.fail(f"FluidAudio pin missing in {path}")
    return None


def check_package_pin(path: Path, state: CheckState, require_version: bool) -> None:
    pin = load_package_pin(path, state)
    if not pin:
        return
    if pin.get("kind") != "remoteSourceControl":
        state.fail(f"FluidAudio pin in {path} must be remoteSourceControl")
    if pin.get("location") != EXPECTED_FLUIDAUDIO_URL:
        state.fail(f"FluidAudio pin in {path} must use {EXPECTED_FLUIDAUDIO_URL}")
    pin_state = pin.get("state") or {}
    if pin_state.get("revision") != EXPECTED_FLUIDAUDIO_REVISION:
        state.fail(
            f"FluidAudio revision drift in {path}: expected {EXPECTED_FLUIDAUDIO_REVISION}, got {pin_state.get('revision')}"
        )
    if require_version and pin_state.get("version") != EXPECTED_FLUIDAUDIO_VERSION:
        state.fail(
            f"SpeakerEval FluidAudio version drift: expected {EXPECTED_FLUIDAUDIO_VERSION}, got {pin_state.get('version')}"
        )


def check_project_package_reference(state: CheckState) -> None:
    text = read_text(ROOT / "Dspeech.xcodeproj/project.pbxproj", state)
    if not text:
        return
    if EXPECTED_FLUIDAUDIO_URL not in text:
        state.fail("Xcode project must reference the canonical FluidAudio repository URL")
    if f"kind = revision; revision = {EXPECTED_FLUIDAUDIO_REVISION};" not in text:
        state.fail("Xcode project must pin FluidAudio by exact revision")
    if "upToNextMajorVersion" in text or "branch =" in text:
        state.fail("Xcode project must not use floating SwiftPM package requirements")


def check_speaker_eval_package(state: CheckState) -> None:
    text = read_text(ROOT / "Dspeech/Tools/SpeakerEval/Package.swift", state)
    if not text:
        return
    expected = f'.package(url: "{EXPECTED_FLUIDAUDIO_URL}", exact: "{EXPECTED_FLUIDAUDIO_VERSION}")'
    if expected not in text:
        state.fail("SpeakerEval Package.swift must pin FluidAudio exact 0.14.7")


def check_model_pack_contract(state: CheckState) -> None:
    path = ROOT / "Dspeech/Core/VoiceFilter/SpeakerModelPackInstaller.swift"
    text = read_text(path, state)
    if not text:
        return
    expected_literals = {
        "packVersion": EXPECTED_FLUIDAUDIO_VERSION,
        "source": EXPECTED_MODEL_SOURCE,
    }
    for name, expected in expected_literals.items():
        pattern = rf'static let {name} = "{re.escape(expected)}"'
        if not re.search(pattern, text):
            state.fail(f"SpeakerModelPackInstaller.{name} must stay pinned to {expected}")
    if (
        "pinnedDownloadURL(relativePath:" not in text
        or "URLSession.shared.download" not in text
        or "Repo.diarizer.folderName" not in text
    ):
        state.fail("SpeakerModelPackInstaller must keep the pinned FluidAudio diarizer download boundary explicit")
    if "ModelRegistry.baseURL" not in text:
        state.fail("SpeakerModelPackInstaller must keep registry base URL handling explicit")
    match = re.search(r"expectedModelFileManifest:\s*\[ExpectedModelFile\]\s*=\s*\[(.*?)\n\s*\]", text, re.S)
    if not match:
        state.fail("SpeakerModelPackInstaller expected model manifest missing")
        return
    manifest = match.group(1)
    entries = re.findall(r"ExpectedModelFile\(", manifest)
    checksums = re.findall(r'sha256:\s*"([0-9a-f]{64})"', manifest)
    if len(entries) != EXPECTED_MODEL_MANIFEST_COUNT:
        state.fail(
            f"Expected {EXPECTED_MODEL_MANIFEST_COUNT} model manifest entries, found {len(entries)}"
        )
    if len(checksums) != EXPECTED_MODEL_MANIFEST_COUNT:
        state.fail(
            f"Expected {EXPECTED_MODEL_MANIFEST_COUNT} model manifest SHA-256 checksums, found {len(checksums)}"
        )
    if len(set(checksums)) != len(checksums):
        state.fail("Model manifest SHA-256 checksums must be unique")


def check_whisperkit_model_installer_contract(state: CheckState) -> None:
    path = ROOT / "Dspeech/Core/ASR/WhisperKitModelInstaller.swift"
    text = read_text(path, state)
    if not text:
        return
    if not re.search(r'static let pinnedRevision = "[0-9a-f]{40}"', text):
        state.fail("WhisperKitModelInstaller must pin a full HF revision SHA")
    if "pinnedDownloadURL(relativePath:" not in text or "huggingface.co" not in text:
        state.fail("WhisperKitModelInstaller must keep the pinned download boundary explicit")
    if '"https://' in text and "resolve/\\(pinnedRevision)" not in text:
        state.fail("WhisperKitModelInstaller downloads must resolve through the pinned revision")


def check_parakeet_model_installer_contract(state: CheckState) -> None:
    path = ROOT / "Dspeech/Core/ASR/ParakeetModelInstaller.swift"
    text = read_text(path, state)
    if not text:
        return
    if not re.search(r'static let sourceRevision = "[0-9a-f]{40}"', text):
        state.fail("ParakeetModelInstaller must pin a full HF revision SHA")
    if "pinnedDownloadURL(relativePath:" not in text or "huggingface.co" not in text:
        state.fail("ParakeetModelInstaller must keep the pinned download boundary explicit")
    if '"https://' in text and "resolve/\\(sourceRevision)" not in text:
        state.fail("ParakeetModelInstaller downloads must resolve through the pinned revision")


def check_production_source_no_unexpected_network(state: CheckState) -> None:
    swift_root = ROOT / "Dspeech"
    for path in sorted(swift_root.rglob("*.swift")):
        relative = path.relative_to(ROOT)
        if "Tools" in relative.parts:
            continue
        text = path.read_text(encoding="utf-8")
        for marker in PRODUCTION_SOURCE_FORBIDDEN_MARKERS:
            if marker in PRODUCTION_SOURCE_NETWORK_ALLOWLIST.get(relative, set()):
                continue
            if marker in text:
                state.fail(f"unexpected production network marker {marker!r} in {relative}")


def validate_privacy_manifest_bytes(data: bytes, state: CheckState, context: str) -> None:
    try:
        manifest = plistlib.loads(data)
    except Exception as exc:
        state.fail(f"{context}: invalid privacy manifest plist: {exc}")
        return
    required_root_keys = {
        "NSPrivacyAccessedAPITypes",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
    }
    missing = required_root_keys - manifest.keys()
    if missing:
        state.fail(f"{context}: missing privacy root keys: {sorted(missing)}")
    if manifest.get("NSPrivacyTracking") is not False:
        state.fail(f"{context}: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        state.fail(f"{context}: NSPrivacyCollectedDataTypes must be empty")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        state.fail(f"{context}: NSPrivacyTrackingDomains must be empty")
    entries = manifest.get("NSPrivacyAccessedAPITypes") or []
    reasons = {
        reason
        for entry in entries
        if entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
        for reason in entry.get("NSPrivacyAccessedAPITypeReasons", [])
    }
    if "CA92.1" not in reasons:
        state.fail(f"{context}: missing UserDefaults reason CA92.1")


def check_source_privacy_manifest(state: CheckState) -> None:
    path = ROOT / "Dspeech/PrivacyInfo.xcprivacy"
    if not path.exists():
        state.fail("source privacy manifest missing")
        return
    validate_privacy_manifest_bytes(path.read_bytes(), state, "source PrivacyInfo.xcprivacy")


def localizable_catalog_locales(state: CheckState) -> set[str]:
    path = ROOT / "Dspeech/Localizable.xcstrings"
    if not path.exists():
        state.fail(f"missing string catalog: {rel(path)}")
        return set()
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        state.fail(f"invalid Localizable.xcstrings JSON: {exc}")
        return set()
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        state.fail("Localizable.xcstrings must contain a strings dictionary")
        return set()
    return {
        locale
        for entry in strings.values()
        if isinstance(entry, dict)
        for locale in (entry.get("localizations") or {}).keys()
    }


def app_store_listing_locales(state: CheckState) -> set[str]:
    listing_dir = ROOT / "docs/product/app-store"
    paths = sorted(listing_dir.glob("listing-*.md"))
    if not paths:
        state.fail("no App Store listing markdown files found")
        return set()
    return {path.stem.removeprefix("listing-") for path in paths}


def check_app_store_listing_locales_have_app_catalog_locale(state: CheckState) -> None:
    listing_locales = app_store_listing_locales(state)
    catalog_locales = localizable_catalog_locales(state)
    missing = sorted(listing_locales - catalog_locales)
    if missing:
        state.fail(
            "App Store listing locale(s) missing from Localizable.xcstrings: "
            + ", ".join(missing)
        )


def source_checks(state: CheckState) -> None:
    check_package_pin(ROOT / APP_PACKAGE_RESOLVED, state, require_version=False)
    check_package_pin(ROOT / SPEAKER_EVAL_PACKAGE_RESOLVED, state, require_version=True)
    check_project_package_reference(state)
    check_speaker_eval_package(state)
    check_model_pack_contract(state)
    check_whisperkit_model_installer_contract(state)
    check_parakeet_model_installer_contract(state)
    check_production_source_no_unexpected_network(state)
    check_source_privacy_manifest(state)
    check_app_store_listing_locales_have_app_catalog_locale(state)


def archive_app_paths(archive_path: Path) -> dict[str, Path]:
    app = archive_path / "Products/Applications/Dspeech.app"
    return {
        "app": app,
        "binary": app / "Dspeech",
        "infoPlist": app / "Info.plist",
        "privacyManifest": app / "PrivacyInfo.xcprivacy",
    }


def required_archive_hashes(archive_path: Path, state: CheckState | None = None) -> dict[str, str]:
    paths = archive_app_paths(archive_path)
    hash_map = {
        "appBinarySHA256": paths["binary"],
        "appInfoPlistSHA256": paths["infoPlist"],
        "appPrivacyManifestSHA256": paths["privacyManifest"],
    }
    hashes: dict[str, str] = {}
    for key, path in hash_map.items():
        if path.exists():
            hashes[key] = sha256_file(path)
        elif state is not None:
            state.fail(f"archive artifact missing for stamp hash {key}: {path}")
    return hashes


def write_stamp(archive_path: Path, stamp_path: Path) -> None:
    package_hash = sha256_file(ROOT / APP_PACKAGE_RESOLVED)
    speaker_eval_hash = sha256_file(ROOT / SPEAKER_EVAL_PACKAGE_RESOLVED)
    try:
        xcode_version = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
    except Exception:
        xcode_version = "unknown"
    try:
        developer_dir = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    except Exception:
        developer_dir = os.environ.get("DEVELOPER_DIR", "unknown")
    archive_hashes = required_archive_hashes(archive_path)
    missing_hashes = sorted({"appBinarySHA256", "appInfoPlistSHA256", "appPrivacyManifestSHA256"} - archive_hashes.keys())
    if missing_hashes:
        raise SystemExit(f"cannot write release build stamp; archive artifacts missing: {missing_hashes}")
    stamp = {
        "schemaVersion": 1,
        "gitHead": git_head(),
        "gitDirty": git_dirty(),
        "packageResolvedSHA256": package_hash,
        "speakerEvalPackageResolvedSHA256": speaker_eval_hash,
        **archive_hashes,
        "fluidAudio": {
            "url": EXPECTED_FLUIDAUDIO_URL,
            "revision": EXPECTED_FLUIDAUDIO_REVISION,
            "version": EXPECTED_FLUIDAUDIO_VERSION,
            "modelSource": EXPECTED_MODEL_SOURCE,
            "modelManifestCount": EXPECTED_MODEL_MANIFEST_COUNT,
        },
        "xcodeVersion": xcode_version,
        "developerDir": developer_dir,
        "archivePath": str(archive_path),
    }
    stamp_path.parent.mkdir(parents=True, exist_ok=True)
    stamp_path.write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote release build stamp: {stamp_path}")


def check_archive(state: CheckState, archive_path: Path, stamp_path: Path) -> None:
    if not archive_path.exists():
        state.fail(f"archive missing: {archive_path}")
        return
    if not stamp_path.exists():
        state.fail(f"build stamp missing: {stamp_path}")
        return
    try:
        stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
    except Exception as exc:
        state.fail(f"invalid build stamp JSON: {exc}")
        return

    expected_head = git_head()
    if stamp.get("gitHead") != expected_head:
        state.fail(f"build stamp gitHead mismatch: expected {expected_head}, got {stamp.get('gitHead')}")
    dirty_allowed = os.environ.get("DSPEECH_ALLOW_DIRTY_RELEASE") == "1"
    if stamp.get("gitDirty") and not dirty_allowed:
        state.fail("build stamp recorded a dirty source tree; set DSPEECH_ALLOW_DIRTY_RELEASE=1 only for non-release dev verification")
    elif stamp.get("gitDirty") and dirty_allowed:
        state.warn("dirty source tree allowed by DSPEECH_ALLOW_DIRTY_RELEASE=1 — not a releasable archive")

    current_app_hash = sha256_file(ROOT / APP_PACKAGE_RESOLVED)
    current_eval_hash = sha256_file(ROOT / SPEAKER_EVAL_PACKAGE_RESOLVED)
    if stamp.get("packageResolvedSHA256") != current_app_hash:
        state.fail("build stamp app Package.resolved hash mismatch")
    if stamp.get("speakerEvalPackageResolvedSHA256") != current_eval_hash:
        state.fail("build stamp SpeakerEval Package.resolved hash mismatch")
    fluid = stamp.get("fluidAudio") or {}
    if fluid.get("revision") != EXPECTED_FLUIDAUDIO_REVISION or fluid.get("version") != EXPECTED_FLUIDAUDIO_VERSION:
        state.fail("build stamp FluidAudio pin drift")
    if Path(stamp.get("archivePath", "")) != archive_path:
        state.fail("build stamp archivePath mismatch")
    for key, current_hash in required_archive_hashes(archive_path, state).items():
        if stamp.get(key) != current_hash:
            state.fail(f"build stamp {key} mismatch")

    paths = archive_app_paths(archive_path)
    app = paths["app"]
    binary = paths["binary"]
    info_plist = paths["infoPlist"]
    privacy = paths["privacyManifest"]
    if not app.exists():
        state.fail(f"archive app bundle missing: {app}")
        return
    if not binary.exists():
        state.fail(f"archive app binary missing: {binary}")
    if not info_plist.exists():
        state.fail(f"archive Info.plist missing: {info_plist}")
    else:
        try:
            info = plistlib.loads(info_plist.read_bytes())
        except Exception as exc:
            state.fail(f"archive Info.plist invalid: {exc}")
        else:
            if info.get("ITSAppUsesNonExemptEncryption") is not False:
                state.fail("archive Info.plist must set ITSAppUsesNonExemptEncryption=false")
            if not info.get("CFBundleShortVersionString"):
                state.fail("archive Info.plist missing CFBundleShortVersionString")
            if not info.get("CFBundleVersion"):
                state.fail("archive Info.plist missing CFBundleVersion")
    if not privacy.exists():
        state.fail(f"archive privacy manifest missing: {privacy}")
    else:
        validate_privacy_manifest_bytes(privacy.read_bytes(), state, "archive PrivacyInfo.xcprivacy")

    if binary.exists():
        data = binary.read_bytes()
        if RELEASE_BINARY_SENTINEL not in data:
            state.fail("release binary string scan unreliable: model source sentinel absent")
        for marker in FORBIDDEN_RELEASE_BINARY_MARKERS:
            if marker in data:
                state.fail(f"DEBUG speech-probe marker leaked into release binary: {marker.decode()}")


def print_results(state: CheckState, success_message: str) -> int:
    if state.warnings:
        print("Warnings:")
        for warning in state.warnings:
            print(f" - {warning}")
    if state.failures:
        print("Release policy check failed:", file=sys.stderr)
        for failure in state.failures:
            print(f" - {failure}", file=sys.stderr)
        return 1
    print(success_message)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Dspeech release supply-chain/privacy policy gate")
    parser.add_argument("--source-only", action="store_true", help="validate source/package/privacy policy only")
    parser.add_argument("--write-stamp", nargs=2, metavar=("ARCHIVE", "STAMP"), help="write archive build stamp after xcodebuild archive")
    parser.add_argument("--archive", type=Path, help="validate built xcarchive")
    parser.add_argument("--stamp", type=Path, help="build stamp path for --archive")
    args = parser.parse_args()

    if args.write_stamp:
        archive_path = Path(args.write_stamp[0]).resolve()
        stamp_path = Path(args.write_stamp[1]).resolve()
        write_stamp(archive_path, stamp_path)
        return 0

    state = CheckState()
    source_checks(state)
    if args.archive or args.stamp:
        if not args.archive or not args.stamp:
            state.fail("--archive and --stamp must be provided together")
        else:
            check_archive(state, args.archive.resolve(), args.stamp.resolve())
        return print_results(state, "Release policy source + archive checks passed.")

    if args.source_only:
        return print_results(state, "Release policy source checks passed.")

    parser.error("choose --source-only, --write-stamp, or --archive/--stamp")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
