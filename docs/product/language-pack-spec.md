# Language-pack & download — specification

Date: 2026-05-18. Status: draft. Required by `prd-ios-mvp.md` (translation toggle) and ADR 0002 (local-only default).

## Purpose

Define how Dspeech bundles, downloads, stores, updates, and deletes on-device translation/ASR models so the app stays local-by-default while remaining App-Store-shippable (binary size limits) and easy for the user to manage.

## What is a "pack"

A pack is one of:

- **ASR pack** — quantized speech model + tokenizer + config (`.mlmodelc` bundle + meta). Example: WhisperKit `small.en` int4 ≈ 150 MB.
- **MT pack** — translation model for a hub+spoke pair or a multilingual hub (e.g. NLLB-distilled covering 20 langs). Example: 250–400 MB per multilingual hub, 80–150 MB per bilingual distill.
- **Glossary pack** — aviation glossary YAML + regex anchors (small, < 1 MB). Bundled in app binary, not downloaded.

Each pack has a manifest entry:

```json
{
  "pack_id": "mt.nllb600m.int8.aviation.v1",
  "kind": "mt",
  "size_mb": 312,
  "languages": ["en","ru","uk","de","fr","es","pt-br","it"],
  "checksum_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "version": "2026-05-18.1",
  "min_ios": "26.0",
  "download_url": "https://packs.dspeech.app/mt/nllb600m_int8_aviation_v1.mlpackage.zip",
  "signing_pubkey_id": "dspeech-pack-key-2026"
}
```

Date format: `YYYY-MM-DD.N` matching corpus version style. Synthetic example — checksum is placeholder.

## Bundling policy

App Store binary ships with:

- The **glossary pack** (always).
- One **ASR pack** that covers EN baseline (smallest viable variant — pre-benchmark estimate ≈ 100 MB).
- **No MT pack pre-bundled** — first-run prompts user to download their first MT pack.

Rationale: keeps initial App Store install < 250 MB (Apple's over-cellular threshold has been ≥ 200 MB historically; verify Apple's current threshold at submission time). Larger ASR variants are optional downloads.

## Storage layout

```
Application Support/dspeech/packs/
  mt/<pack_id>/        # extracted model bundle
  asr/<pack_id>/
  manifest.json        # local manifest (installed packs)
  signatures/<pack_id>.sig
```

`Application Support` (not Caches) so iOS doesn't evict packs under storage pressure. Backups: excluded via `NSURLIsExcludedFromBackupKey = true` (user re-downloads on restore — keeps iCloud backup small and avoids "we sent your audio model to iCloud" confusion).

## Catalog & versioning

- Catalog endpoint: `https://packs.dspeech.app/catalog.json` (read-only). Pinned via CloudFront/Cloudflare.
- Client fetches catalog on app launch (if network available) and on user-tap of "Check for pack updates". Catalog fetch is metadata-only (no audio leaves the device — consistent with `.localOnly`).
- Each pack signed with project ed25519 key; signature verified on install before extraction.
- Pack updates are opt-in: user sees "New version available for pack X (Y MB)", can decline.

## Download UX

- "Download pack — N MB" CTA inside Settings → Translation. Tap → progress bar, can cancel, retries on transient failure (HTTP 5xx, network drop).
- Download must respect "Cellular data" toggle: default to Wi-Fi only; user can override.
- After download: signature verify → extract → atomic rename → reload model. Failed verification → delete bytes, surface error, never use partial bytes.

## Deletion

- Per-pack delete button in Settings. Confirmation modal: "Free N MB. You can re-download anytime."
- "Free up space" Settings action lists packs by last-used date.
- Active pack cannot be deleted while in use; show "stop translation first".

## Privacy posture

- Catalog fetch sends: app version, iOS version, device model (for compat filtering), pack-id installed list (for delta updates). No audio, no transcripts, no user identifier, no IP-trackable cookie.
- This metadata is permissible under `.localOnly` because audio/transcript content never leaves; ADR 0002 wording covers this explicitly under "metadata for software updates".
- Verify wording in `regulatory-privacy-memo.md` matches.

## Server side (NOT in scope this dispatch)

- Pack hosting CDN: TBD (Cloudflare R2 + Workers most likely). Document when implementation begins.
- Pack build pipeline: training/conversion in `dspeech-packs/` (separate repo, to be created). Not built here.

## Open questions (Andrei action required)

- Approve domain `packs.dspeech.app` (DNS + cert), or pick alternate host.
- Decide initial supported language pairs (default proposal: EN→RU, EN→ES; expand after benchmark).
- Approve catalog-fetch metadata payload (above) as compatible with the local-only marketing claim.

## References

- ADR 0001, ADR 0002, `prd-ios-mvp.md`, `translation-benchmark-plan.md`, `cloud-fallback-matrix.md`, `regulatory-privacy-memo.md`.
