# W1 — TransmissionAssembler (spec §3): pure core + unit/property tests

Read `.ai/runs/2026-06-12-core-rebuild/brief-common.md` first.

## Files you own

- `Dspeech/Core/ASR/TransmissionAssembler.swift` (new)
- `DspeechTests/TransmissionAssemblerTests.swift` (new)
- pbxproj registration ONLY for these two files. Assigned IDs:
  - `A00000000000000000000932` fileRef + `A00000000000000000000933` buildFile for
    TransmissionAssembler.swift (app target Sources phase `A00000000000000000000018`,
    group `ASR`).
  - `A00000000000000000000934` fileRef + `A00000000000000000000935` buildFile for
    TransmissionAssemblerTests.swift (test target Sources phase
    `A00000000000000000000021`, group `DspeechTests`).

## Why this exists (product semantics)

The product unit is a TRANSMISSION: one continuous dispatcher radio message, possibly
containing short pauses, shown as ONE permanent block. The ASR engine instead emits
~1s-window partials/finals and recycles its recognition task on silence — those
fragments are INTERNAL and must never be UI units. The assembler turns the fragment
stream into whole transmissions. Defect it fixes: D-1 (a task recycle replaced on-screen
text) and D-2 fragmentation (3-5-word cards).

## Public API (binding contract — Claude's harness and the VM will call exactly this)

```swift
struct TransmissionAssemblerConfig: Equatable, Sendable {
  var transmissionGapSeconds: TimeInterval  // default 3.5, valid range 2...6 (clamp)
  var overlapMergeMinWords: Int             // default 2
  static let `default`: TransmissionAssemblerConfig
}

enum TransmissionAssemblerInput: Sendable {
  case partial(text: String, at: Date)
  case fragment(segment: TranscriptSegment, speaker: SpeakerMatchDecision?, at: Date)
  case taskRestart(at: Date)
}

struct TransmissionAssembler {
  init(
    config: TransmissionAssemblerConfig,
    localeIdentifier: String,
    classify: @escaping @Sendable (_ text: String, _ speakers: [SpeakerMatchDecision])
      -> TransmissionClassification
  )

  mutating func process(_ input: TransmissionAssemblerInput) -> [TransmissionUpdate]
  mutating func tick(now: Date) -> [TransmissionUpdate]
  mutating func finish(at: Date) -> [TransmissionUpdate]
}
```

`fragment` covers BOTH real finals and interim restart commits (the
`TranscriptSegment.isInterimRestartCommit` flag distinguishes them — the segment is
already constructed by the engine). `Transmission`, `TransmissionUpdate`,
`TransmissionClassification` come from `Dspeech/Core/Models/Transmission.swift` (on the
branch — read it). `SpeakerMatchDecision` is in `Dspeech/Core/VoiceFilter/SpeakerMatcher.swift`.

## Behavior (spec §3.2-§3.4, §2.1, §2.3 — binding)

1. **Open** at first speech evidence: a non-empty `partial` or a `fragment` while no
   transmission is open → emit `.opened` with startedAt = that event's `at`.
2. **Stay open** across silence gaps `< transmissionGapSeconds` and across
   `taskRestart` markers (a restart is NOT a boundary).
3. **Close** when `tick(now:)` or any input observes that `now - lastSpeechEvidenceAt
   >= transmissionGapSeconds` → emit `.closed` for the open transmission BEFORE
   processing the new input (so a fragment after a long gap closes the old transmission
   and opens a new one in the same `process` call's returned updates). `finish(at:)`
   closes unconditionally (session stop).
4. **Text accumulation**: only `fragment` inputs contribute text. Join consecutive
   fragments with a single space. Partials NEVER mutate transmission text (they only
   count as speech evidence for open/keep-open) — the live partial renders elsewhere.
5. **Overlap-merge (§3.3)**: when appending a fragment, tokenize both the existing text's
   suffix and the new fragment case-insensitively and punctuation-insensitively
   (alphanumerics-only tokens, like `WordErrorRate.tokenize` in
   `Dspeech/Tools/ReplayKit/Sources/DspeechReplayKit/ReplayKitCommand.swift`); find the
   LONGEST k ≥ `overlapMergeMinWords` where the last k tokens of existing text equal the
   first k tokens of the new fragment; drop those k tokens' span from the new fragment
   before joining (preserve the new fragment's remaining original characters, not the
   normalized tokens). If the new fragment is entirely contained in the existing text's
   token-suffix (k == new fragment's token count), append nothing. This makes replay-tail
   re-transcription and restart double-transcription safe.
6. **Monotonic growth (§2.1/§2.3)**: within an open transmission the accumulated text
   only ever grows (append-only after overlap collapse). Nothing may clear or replace it.
7. **Classification (§3.4)**: keep all `speaker` evidence seen this transmission; after
   EVERY text change call `classify(fullText, speakers)`; if the classification CHANGED,
   the emitted `.updated`/`.opened` carries the new classification (e.g. callsign arrives
   in word 6 and upgrades `.filtered(.nonRelevant)` → `.displayed(.callSignMatch)`).
8. **Segments**: the `Transmission.segments` array carries the contributing
   `TranscriptSegment`s in arrival order.
9. Every mutation returns the minimal correct updates: `.opened` once per transmission,
   `.updated` on text/classification change, `.closed` once. No update when nothing
   changed (e.g. a `tick` with no open transmission, an exact-duplicate fragment).
10. Pure: no clock reads, no I/O, no globals — time comes ONLY from `at:`/`now:` params.

## Tests (same file, Swift Testing)

Unit: open-on-partial, open-on-fragment, gap-close via tick, gap-close via late fragment
(close+open in one call), restart-marker does NOT close, finish closes, space joining,
overlap collapse (2-word, 3-word, full-containment, no-overlap below min words,
case/punctuation-insensitive overlap), classification upgrade mid-transmission emits
update, duplicate fragment emits nothing, partials don't change text, clamp of
out-of-range gap config.

Property (seeded RNG, ≥500 generated cases): random event sequences →
(a) concatenated text of any open transmission is monotonically non-decreasing across
the sequence; (b) every `.opened` id is later `.closed` exactly once after `finish`;
(c) updates never reference a closed id again; (d) transmission texts never contain a
k ≥ overlapMergeMinWords immediate token repetition introduced by merging (verify by
constructing fragment streams WITH artificial overlaps from a known ground-truth string
and asserting the assembled text equals the ground truth).
