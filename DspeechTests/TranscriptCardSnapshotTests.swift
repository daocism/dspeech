import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import Dspeech

// F7 — Snapshot regression suite for the three transcript card views.
//
// Reference configuration (documented so a drift in any of these invalidates the committed PNGs):
//   • Device:   iPhone 17 Pro simulator (portrait width pinned to 393 pt in the host container).
//   • OS:       iOS 26.x.
//   • Scale:    @3x (traits.displayScale = 3).
//   • Scheme:   dark (the app is dark-locked; the container paints DspeechTheme.backgroundBottom).
//   • Motion:   the card entrance transition is inert in a still image, so a static frame is stable
//               regardless of the reduce-motion setting.
//   • Precision: perceptual 0.98 (≈ human eye) + pixel 0.98, to absorb GPU antialiasing noise.
//
// Why the suite is host-gated (see `SnapshotReference`): image snapshots are GPU/host-specific
// (swift-snapshot-testing's own docs: "snapshots must be compared using the exact same simulator
// that originally took the reference"), and these cards use `.glassEffect`, whose material blur is
// especially non-deterministic across machines. Recording on mac24 and diffing on a hosted runner
// would produce flaky reds — exactly the CI-theater this repo avoids (the exhaustive zero-flake bar
// lives on the local mac24 gate; hosted CI is smoke). So the pixel comparison runs ONLY on the
// pinned reference simulator AND off-CI. On any other host the suite is skipped (honest, not
// vacuous — it is recorded + verified locally, and the run-twice determinism proof is the evidence).
//
// Dynamic Type is driven through the SwiftUI environment (`.dynamicTypeSize`) because the card views
// read `@Environment(\.dynamicTypeSize)`; each card is captured at {default, AX-XXXL}.
//
// Locale axis: the badge reason labels are produced by `String(localized:)`, which resolves against
// the process's runtime language, NOT the SwiftUI environment locale — so a unit snapshot cannot
// switch to German text. The "de" axis of the F7 plan is therefore realized as a width-stress
// fixture (longest reason label + long utterance) that catches the same wrap/truncation regressions;
// true per-locale German rendering is covered by the German longest-locale UI sweep
// (AccessibilityAuditUITests / F11-F12 / H12), not by these unit snapshots.
//
// Expanded card state: `TransmissionTranscriptCard`/`TranscriptSegmentCard` gate their detail row on
// a private `@State expanded` toggled by a tap, which a static snapshot cannot drive; the collapsed
// badge-row + utterance surface (the primary layout-regression target) is what is captured here, and
// tap-to-expand is covered by the UI test (F14).

enum SnapshotReference {
  static var isPinnedReferenceSimulator: Bool {
    let environment = ProcessInfo.processInfo.environment
    let device = environment["SIMULATOR_DEVICE_NAME"] ?? ""
    let runtime = environment["SIMULATOR_RUNTIME_VERSION"] ?? ""
    return device == "iPhone 17 Pro" && runtime.hasPrefix("26")
  }

  static var isContinuousIntegration: Bool {
    ProcessInfo.processInfo.environment["CI"] != nil
  }

  // why: only diff pixels where the reference was recorded (pinned sim) and where a GPU/host match
  // is guaranteed (off-CI, i.e. mac24). Everywhere else the suite skips rather than flake.
  static var isEnabled: Bool { isPinnedReferenceSimulator && !isContinuousIntegration }

  static let containerWidth: CGFloat = 393

  // why: @MainActor because UITraitCollection(mutations:) is main-actor-isolated; read only from the
  // @MainActor snapshot helpers. `isEnabled` above stays nonisolated for the .enabled(if:) trait.
  @MainActor static let traits = UITraitCollection { mutableTraits in
    mutableTraits.userInterfaceStyle = .dark
    mutableTraits.displayScale = 3
  }

  @MainActor
  static func host(_ view: some View, dynamicType: DynamicTypeSize) -> some View {
    view
      .frame(width: containerWidth, alignment: .leading)
      .padding(16)
      .background(DspeechTheme.backgroundBottom)
      .environment(\.colorScheme, .dark)
      .environment(\.dynamicTypeSize, dynamicType)
  }

  static let dynamicTypeCases: [(tag: String, size: DynamicTypeSize)] = [
    ("default", .large),
    ("axxxl", .accessibility5),
  ]
}

@MainActor
@Suite(.snapshots(record: .missing), .enabled(if: SnapshotReference.isEnabled))
struct TranscriptCardSnapshotTests {
  // Fixed identity + timestamps so nothing time/UUID-dependent leaks into a frame.
  private static let fixedDate = Date(timeIntervalSince1970: 1_718_000_000)

  private func assertCardSnapshots(
    _ name: String,
    _ view: some View,
    function: String = #function,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for dynamicType in SnapshotReference.dynamicTypeCases {
      assertSnapshot(
        of: SnapshotReference.host(view, dynamicType: dynamicType.size),
        as: .image(
          precision: 0.98,
          perceptualPrecision: 0.98,
          layout: .sizeThatFits,
          traits: SnapshotReference.traits
        ),
        named: "\(name)-\(dynamicType.tag)",
        file: file,
        testName: function,
        line: line
      )
    }
  }

  // MARK: - Fixtures

  private static func segment(
    text: String,
    translatedText: String? = nil,
    confidence: Double,
    languageCode: String = "en",
    source: TranscriptSegment.Source = .liveATC
  ) -> TranscriptSegment {
    TranscriptSegment(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
      startedAt: fixedDate,
      text: text,
      translatedText: translatedText,
      confidence: confidence,
      sourceLanguageCode: languageCode,
      source: source
    )
  }

  private static func transmission(
    text: String,
    classification: TransmissionClassification,
    localeIdentifier: String = "en-US"
  ) -> Transmission {
    Transmission(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
      startedAt: fixedDate,
      endedAt: fixedDate.addingTimeInterval(5),
      text: text,
      segments: [],
      classification: classification,
      localeIdentifier: localeIdentifier
    )
  }

  // MARK: - TranscriptSegmentCard

  @Test func transcriptSegmentCardEnglishHighConfidence() {
    assertCardSnapshots(
      "segment-en-high-confidence",
      TranscriptSegmentCard(
        segment: Self.segment(
          text: "DELTA FOUR FIVE SEVEN CLEARED TO LAND RUNWAY TWO SEVEN LEFT",
          confidence: 0.94
        ),
        translatedText: nil,
        isLandscape: false
      )
    )
  }

  @Test func transcriptSegmentCardVerifyBadgeLowConfidence() {
    assertCardSnapshots(
      "segment-verify-low-confidence",
      TranscriptSegmentCard(
        segment: Self.segment(
          text: "SPEEDBIRD ONE TWO HEAVY HOLD SHORT RUNWAY TWO SEVEN",
          confidence: 0.5
        ),
        translatedText: nil,
        isLandscape: false
      )
    )
  }

  @Test func transcriptSegmentCardDemoWithTranslationGloss() {
    assertCardSnapshots(
      "segment-demo-translated",
      TranscriptSegmentCard(
        segment: Self.segment(
          text: "TURN LEFT HEADING ZERO NINER ZERO",
          translatedText: "Nach links drehen auf Steuerkurs null neun null",
          confidence: 0,
          source: .demo
        ),
        translatedText: "Nach links drehen auf Steuerkurs null neun null",
        isLandscape: false
      )
    )
  }

  // why: width-stress standing in for the German longest-locale axis (see file header).
  @Test func transcriptSegmentCardLongUtteranceWidthStress() {
    assertCardSnapshots(
      "segment-long-stress",
      TranscriptSegmentCard(
        segment: Self.segment(
          text:
            "LUFTHANSA FOUR FIVE SIX SEVEN DESCEND AND MAINTAIN FLIGHT LEVEL ONE ZERO ZERO "
            + "EXPECT VECTORS FOR THE ILS APPROACH RUNWAY TWO FIVE RIGHT REDUCE SPEED ONE EIGHT ZERO KNOTS",
          translatedText: nil,
          confidence: 0.88
        ),
        translatedText: nil,
        isLandscape: false
      )
    )
  }

  // MARK: - TransmissionTranscriptCard (collapsed badge row + utterance)

  @Test func transmissionCardOwnCallsign() {
    assertCardSnapshots(
      "transmission-own-callsign",
      TransmissionTranscriptCard(
        transmission: Self.transmission(
          text: "DELTA FOUR FIVE SEVEN LINE UP AND WAIT RUNWAY TWO SEVEN LEFT",
          classification: .displayed(.callSignMatch)
        ),
        isLandscape: false
      )
    )
  }

  @Test func transmissionCardUrgencyBroadcast() {
    assertCardSnapshots(
      "transmission-urgent",
      TransmissionTranscriptCard(
        transmission: Self.transmission(
          text: "MAYDAY MAYDAY MAYDAY ENGINE FAILURE DECLARING EMERGENCY",
          classification: .displayed(.urgencyBroadcast)
        ),
        isLandscape: false
      )
    )
  }

  // why: longest reason label (.filtered(.addressedToOther)) + long text = the width-stress axis.
  @Test func transmissionCardLongReasonWidthStress() {
    assertCardSnapshots(
      "transmission-long-stress",
      TransmissionTranscriptCard(
        transmission: Self.transmission(
          text:
            "AIR FRANCE THREE TWO ONE CONTACT DEPARTURE ONE TWO FIVE DECIMAL EIGHT FIVE "
            + "GOOD DAY MAINTAIN RUNWAY HEADING CLIMB FLIGHT LEVEL SEVEN ZERO",
          classification: .filtered(.addressedToOther)
        ),
        isLandscape: false
      )
    )
  }

  // MARK: - PartialTranscriptCard

  @Test func partialTranscriptCardEnglish() {
    assertCardSnapshots(
      "partial-en",
      PartialTranscriptCard(
        text: "UNITED TWO THREE CLEARED FOR TAKEOFF",
        isLandscape: false
      )
    )
  }

  @Test func partialTranscriptCardLongWidthStress() {
    assertCardSnapshots(
      "partial-long-stress",
      PartialTranscriptCard(
        text:
          "KLM SIX FIVE FOUR TAXI TO HOLDING POINT ALPHA THREE VIA TAXIWAY BRAVO "
          + "HOLD SHORT OF RUNWAY ONE EIGHT CONTACT TOWER ONE ONE EIGHT DECIMAL ONE",
        isLandscape: false
      )
    )
  }
}
