# Snapshot test scaffolding — design only

> **Status:** design blueprint. No Swift, no SPM dependency, no `.gitignore` change.
> **Scope:** the three highest-blast-radius SwiftUI surfaces:
> `PrivacyBadge` (main UI), `FirstRunView` (welcome / privacy / consent cards),
> `AboutView` (footer + attribution).
> **Branch:** `burn/11-snapshot-test-design` (worktree-pinned; do not switch).
> **Authority:** product rules in repo `CLAUDE.md` and ADR 0002 (privacy).
> The privacy badge being visible at all times is a hard product rule
> (`CLAUDE.md` rule 4); a snapshot regression on it is a P0 break, not cosmetic.

## 1. Why snapshots, why now, and why only these three

XCUITest already asserts the badge exists, that taps work, and that the right
identifiers are reachable. What XCUITest does **not** catch:

- Silent layout regression where the badge still has `accessibilityIdentifier`
  `privacy-badge` but visually disappears under a tint change, a clipped capsule,
  or a Dynamic Type bump that pushes it under the safe-area.
- First-run copy edits that ship without anyone noticing the title now wraps to
  four lines at AX3 and pushes the continue button off-screen.
- About-view licensing / attribution rows getting reordered or losing the
  privacy badge in the footer.

A snapshot is the cheap, deterministic backstop for **rendered output** the same
way `PrivacySettingsTests.userDefaultsRoundTrip` is for **persisted state**.
Three surfaces only: the goal is high signal-per-baseline, not coverage theatre.

## 2. Library candidate review (cite or mark `UNKNOWN`)

### 2.1 `pointfreeco/swift-snapshot-testing` (primary candidate)

- **Repo:** <https://github.com/pointfreeco/swift-snapshot-testing>
- **License:** MIT (verified by inspecting `LICENSE` on `main` at any commit).
- **iOS 26 / Swift 6 strict-concurrency status:** `UNKNOWN — verify before
  adoption.` The library has shipped Swift 6 fixes in the 1.17.x line, but the
  exact tag with green CI on `Xcode 26.0 + iOS 26.0 Simulator` must be
  re-checked at the moment of adoption — pin to a tag, never `from: "1.0.0"`.
- **Recommended call shape (do not invent flags):**
  `assertSnapshot(of: view, as: .image(layout: .device(config: .iPhone17Pro), traits: .init(userInterfaceStyle: .dark)))`
  — confirm the exact `.image` / `.fixed` / `.sizeThatFits` strategy names and
  the available `ViewImageConfig` device cases against the tag's `Sources/`
  before writing tests. Anything I claim about the API here without a tag is
  `UNKNOWN`.
- **Storage footprint:** PNGs land beside the test file in
  `__Snapshots__/<TestClassName>/<testFunctionName>.<n>.png`. Empirical
  per-PNG cost for a phone-sized surface is roughly 30–150 KB; AX3 + dark mode
  raises it because text rasterizes at higher resolution. Budget the matrix
  ahead of time (see §5).
- **Why this candidate:** by far the most-used Swift snapshot library; mature
  diff tooling; works in `XCTest` (which is what `DspeechUITests` already
  uses). It is the default for any team that has not deliberately rejected it.

### 2.2 Native `XCTAttachment` + manual `PNGData` diff

- No external dependency. Stamp the image with
  `XCUIScreen.main.screenshot().image`, write to disk, compare via your own
  `Data.elementwiseEqual`. Apple's `XCTAttachment` retains failure artifacts.
- **Pros:** zero supply-chain surface; matches existing XCUITest pipeline.
- **Cons:** you re-implement what point-free already solved — pixel-tolerance
  thresholds, perceptual diff, named baselines, fixture invalidation on
  Xcode-version bumps. Reserve this path only if §2.1 is genuinely blocked on
  Swift 6 strict-concurrency.

### 2.3 Apple's `Xcode 26` reference-image testing

- `UNKNOWN — verify before adoption.` Xcode has shipped reference-image
  comparison hooks in `XCTest` over the years; whether the surface in
  `Xcode 26` is officially documented and stable on iOS 26 simulators is
  unknown from inside this design doc. Do not adopt without a doc link.

### 2.4 What is explicitly out of scope

- Any "AI-powered visual diff" SaaS. No outbound network from CI per repo
  `CLAUDE.md` rule "Local-only is the default" (and ADR 0002).
- Percy / Chromatic / Applitools. Same reason.
- Custom in-repo forks of snapshot libraries.

## 3. Surface inventory — owning files are read-only references

> Each row is a snapshot anchor. **Owning file is referenced, never edited from
> this dossier.** If an anchor is missing for a target, the row is marked as a
> follow-up task; we do not propose modifying app source from a test-design
> doc.

### 3.1 `PrivacyBadge`

| Field                       | Value                                                              |
|-----------------------------|--------------------------------------------------------------------|
| Owning file (read-only)     | `Dspeech/App/ContentView.swift:254-273`                            |
| Stable a11y identifier      | `privacy-badge`                                                    |
| Stable a11y label (LOCAL)   | `Локальная обработка`                                              |
| Stable a11y label (CLOUD)   | `Облачная обработка (с согласия)`                                  |
| Visible text (LOCAL)        | `LOCAL` (green tint, capsule)                                      |
| Visible text (CLOUD)        | `CLOUD` (orange tint, capsule)                                     |
| Layout knob                 | `isLandscape` toggles font size (10pt landscape / 11pt portrait)   |
| Light/dark surface          | Both. Badge ships embedded in a dark gradient in `ContentView`, but the view itself does not force a scheme — the snapshot test must explicitly drive `userInterfaceStyle` to keep the matrix honest. |
| Dynamic Type expectation    | All three of `xSmall`, `medium`, `accessibility3` must remain legible inside the capsule (visual diff catches truncation). |
| Recommended matrix          | 2 modes × 2 schemes × 3 type sizes = **12 cases**                  |
| Decision                    | **GO** (P0 product invariant per `CLAUDE.md` rule 4)               |

### 3.2 `FirstRunView` — cards

| Field                       | Value                                                              |
|-----------------------------|--------------------------------------------------------------------|
| Owning file (read-only)     | `Dspeech/App/FirstRunView.swift`                                   |
| Root a11y identifier        | `first-run-view` (line 181)                                        |
| Skip-bar button identifier  | `first-run-skip` (line 193)                                        |
| Card title identifier       | `first-run-card-title` (line 210)                                  |
| Error banner identifier     | `first-run-error` (line 227, only when `viewModel.lastError != nil`) |
| Per-card identifier         | `first-run-card-<N>` where N ∈ {1,2,3}                             |
| Language picker identifier  | `first-run-target-language-picker` (last card only, line 247)      |
| Primary CTA identifier      | `first-run-continue` (lines 281 and 289 — same id on both branches; intentional, that is the anchor) |
| Forced color scheme         | `.dark` is forced on the view (`preferredColorScheme(.dark)`, line 179). Light snapshots would lie — **only dark variants are produced.** |
| Cards in order              | 1 `receiveOnly` — title `Только приём`, SF Symbol `antenna.radiowaves.left.and.right`<br>2 `localByDefault` — title `Локально по умолчанию`, SF Symbol `lock.iphone`<br>3 `wireForAccuracy` — title `Подключите гарнитуру`, SF Symbol `cable.connector` + language picker |
| Dynamic Type expectation    | `medium` + `accessibility3` (XS adds noise without catching anything the medium baseline misses on this layout) |
| Recommended matrix          | 3 cards × 1 scheme (dark only) × 2 type sizes = **6 cases**         |
| Decision                    | **GO** for cards 1 and 2 (privacy-explainer surface, ADR 0002 visible affordances). **GO** for card 3 (it owns the language picker; regression here = silent loss of the only target-language affordance in onboarding). |

### 3.3 `AboutView`

| Field                       | Value                                                              |
|-----------------------------|--------------------------------------------------------------------|
| Owning file (read-only)     | `Dspeech/App/AboutView.swift`                                      |
| Root a11y identifier        | `about-view` (line 62)                                             |
| App-name row                | `about-app-name` (line 9)                                          |
| Version row                 | `about-version` (line 11)                                          |
| Embedded privacy badge      | `about-privacy-badge` (line 18; wraps `LocalOnlyBadge`)            |
| Attribution row (speech)    | `about-attribution-apple-speech` (line 31)                         |
| Attribution row (translation)| `about-attribution-translation` (line 36)                         |
| Licenses section            | `about-licenses` (line 51)                                         |
| Forced color scheme         | `.dark` is forced (`preferredColorScheme(.dark)`, line 61). **Only dark variants are produced.** |
| Dynamic Type expectation    | `medium` + `accessibility3`                                        |
| Recommended matrix          | 1 view × 1 scheme (dark only) × 2 type sizes = **2 cases**          |
| Decision                    | **GO** (the `LocalOnlyBadge` embed must remain visible — same ADR 0002 invariant as §3.1, applied to the secondary surface) |

### 3.4 Surfaces deliberately excluded

- `SettingsSheet` (`Dspeech/App/SettingsSheet.swift`) — high churn; would
  generate noisy diffs every time a row reorders. XCUITest a11y assertions
  remain the right tool here. **DEFER** until churn settles.
- `LiveTranscription` cards — animated and timing-dependent; snapshots are not
  the right testing primitive. **DEFER.**

## 4. Proposed directory layout (proposal, not commit)

```
DspeechTests/
  Snapshots/                              # source files
    PrivacyBadgeSnapshotTests.swift
    FirstRunCardsSnapshotTests.swift
    AboutViewSnapshotTests.swift
  __Snapshots__/                          # baseline PNGs (committed)
    PrivacyBadgeSnapshotTests/
      testLocal_light_xSmall.1.png
      testLocal_light_medium.1.png
      testLocal_light_ax3.1.png
      testLocal_dark_xSmall.1.png
      testLocal_dark_medium.1.png
      testLocal_dark_ax3.1.png
      testCloud_light_xSmall.1.png        # ...12 total
    FirstRunCardsSnapshotTests/
      testCard1_dark_medium.1.png
      testCard1_dark_ax3.1.png
      testCard2_dark_medium.1.png
      testCard2_dark_ax3.1.png
      testCard3_dark_medium.1.png         # last card, language picker visible
      testCard3_dark_ax3.1.png
    AboutViewSnapshotTests/
      testAbout_dark_medium.1.png
      testAbout_dark_ax3.1.png
```

Total baseline = 20 PNGs. At an estimated mid-range 80 KB/PNG that is ~1.6 MB
of binary added to git history per regeneration — acceptable for the signal,
small enough not to bloat clone time meaningfully.

## 5. Cost-benefit vs the existing XCUITest a11y assertions

XCUITest already covers: **identifier reachable**, **tap dispatches**,
**accessibilityLabel matches expected localized string**. Those are necessary,
not sufficient. Snapshots add:

- **Visual layout regression** (the badge still exists but is clipped under a
  navigation accessory; the AX3 first-run title eats the continue button).
- **Tint and capsule integrity** (a refactor that swaps `.green` for `.gray`
  in `LOCAL` mode would pass every XCUITest assertion and still be a P0
  product violation under `CLAUDE.md` rule 4 and ADR 0002).
- **Cross-Dynamic-Type stability** at the matrix that ships, not just
  default-size.

Snapshots are **not worth** the diff cost when:

- The surface churns weekly (`SettingsSheet`).
- The surface depends on animation timing or transient model state
  (live transcript).
- The surface is gated by data we cannot make deterministic in test
  (server-driven content — does not apply here, repo is local-only).

## 6. Decision matrix

| Surface                                   | Cases | Decision | Rationale                                               |
|-------------------------------------------|-------|----------|---------------------------------------------------------|
| `PrivacyBadge` LOCAL × {light,dark} × {XS,M,AX3} | 6     | **GO**   | P0 visibility invariant (rule 4); cheap matrix; tint regression is exactly what XCUITest misses. |
| `PrivacyBadge` CLOUD × {light,dark} × {XS,M,AX3} | 6     | **GO**   | Same as above; the CLOUD orange-tint contract is the signal that distinguishes consented egress from local-only. |
| `FirstRunView` card 1 (receiveOnly) × dark × {M,AX3} | 2     | **GO**   | First impression; privacy-explainer copy under AX3 is the historical break-point. |
| `FirstRunView` card 2 (localByDefault) × dark × {M,AX3} | 2     | **GO**   | Direct visualization of ADR 0002. |
| `FirstRunView` card 3 (wireForAccuracy + lang picker) × dark × {M,AX3} | 2     | **GO**   | Last card carries the only onboarding-time language picker; high consequence. |
| `AboutView` × dark × {M,AX3}              | 2     | **GO**   | Houses the secondary privacy-badge embed and attribution rows. |
| `SettingsSheet`                           | n/a   | **DEFER**| Churn-heavy; a11y assertions remain the right tool until layout settles. |
| `LiveTranscription` cards                 | n/a   | **DEFER**| Animation + transient state; snapshots would be flaky. |

Total approved baseline: **20 PNGs / 8 test methods / 3 test files.**

## 7. Constraints honored

- No new Swift file in this commit (design doc only).
- No SPM `Package.swift` edit, no `Package.resolved` mutation.
- No `.gitignore` edit (the `__Snapshots__/` baseline is intended to be
  committed; ignoring it would defeat the purpose).
- No claim about `swift-snapshot-testing` API surface that I am not able to
  ground in a specific tag — all such claims above are tagged
  `UNKNOWN — verify before adoption.`
- No proposed change to any app source file. Every identifier cited already
  exists in `main` at the SHAs listed in §3. If a future surface lacks an
  anchor, the follow-up is a separate task to add the identifier, not to
  invent one in a snapshot test.

## 8. Follow-up tasks (separate branches, not this one)

1. Pin a verified `pointfreeco/swift-snapshot-testing` tag and add it to
   `Package.swift` — independent commit, owned by the SPM-config task.
2. Land `DspeechTests/Snapshots/*.swift` with the 8 test methods from §6,
   one file per surface — independent commit.
3. Generate baselines on `iPhone 17 Pro` simulator (the canonical target in
   `CLAUDE.md` "Build & test") under `iOS 26.4` — independent commit, large
   binary diff isolated for review.
4. Wire a CI check that fails on baseline mismatch (no auto-record in CI;
   regeneration is a deliberate, reviewed commit).

## 9. Handoff line (for `docs/AUTOPILOT-JOURNAL.md`, appended by the journal-owning task)

`[burn snapshot-test-design] DONE — file: docs/snapshot-tests-design.md, surfaces=3 (PrivacyBadge, FirstRunView, AboutView), cases=20, branch: burn/11-snapshot-test-design @ <sha-of-this-commit>`

> The journal file is outside this task's `owned_files`. Per the quality gate
> ("`git diff --name-only HEAD~1` returns exactly the owned file"), the
> append is left to the operator / journal-owning task; the line above is
> provided verbatim so it can be appended without re-deriving it.
