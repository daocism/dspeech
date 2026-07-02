import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import Dspeech

// F8 — Snapshot regression suite for the chip/badge system (post-D14 two-tier: filled vs outline).
//
// Reference configuration and host-gating are shared with the transcript-card suite; see
// `SnapshotReference` (TranscriptCardSnapshotTests.swift) for the full rationale. In short: image
// snapshots are GPU/host-specific and these chips use `.glassEffect`, so the pixel comparison runs
// ONLY on the pinned iPhone 17 Pro / iOS 26.x simulator AND off-CI, recorded + verified on mac24.
//
// Covered chips (each independently instantiable via @testable import): PrivacyBadge (LOCAL),
// RouteHealthChip across all five RouteHealth states, and FilteredCountPill. Each is captured at
// {default, AX-XXXL}. PrivacyBadge/RouteHealthChip render inside a GlassEffectContainer with a live
// Namespace because PrivacyBadge takes a `glassNamespace` and uses `glassEffectID` (D9). The
// filled-vs-outline TIER contrast itself is exercised in situ by the transcript-card badge rows
// (F7 — locale/DEMO/LIVE outline capsules vs VERIFY/reason filled capsules); this suite pins the
// standalone chip types the control bar and banners compose.

private struct GlassBadgeHost<Content: View>: View {
  let content: (Namespace.ID) -> Content
  @Namespace private var glassNamespace

  var body: some View {
    GlassEffectContainer {
      content(glassNamespace)
    }
  }
}

@MainActor
@Suite(.snapshots(record: .missing), .enabled(if: SnapshotReference.isEnabled))
struct BadgeChipSnapshotTests {
  private func assertChipSnapshots(
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

  // MARK: - PrivacyBadge (mandatory LOCAL cockpit chrome — ADR 0002)

  @Test func privacyBadgeLocal() {
    assertChipSnapshots(
      "privacy-badge-local",
      GlassBadgeHost { namespace in
        PrivacyBadge(mode: .localOnly, glassNamespace: namespace)
      }
    )
  }

  // MARK: - RouteHealthChip (all five states)

  @Test func routeHealthChipAllStates() {
    let states: [(String, RouteHealth)] = [
      ("suitable-external", .suitableExternal),
      ("caution-builtin", .cautionBuiltIn),
      ("unsuitable-output-only", .unsuitableOutputOnly),
      ("unknown-external", .unknownExternal),
      ("no-input", .noInput),
    ]
    for (tag, health) in states {
      assertChipSnapshots("route-health-\(tag)", RouteHealthChip(health: health))
    }
  }

  // MARK: - FilteredCountPill

  @Test func filteredCountPill() {
    assertChipSnapshots(
      "filtered-count-pill",
      FilteredCountPill(count: 7, onReview: {})
    )
  }
}
