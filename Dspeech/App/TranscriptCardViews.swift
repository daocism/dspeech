import SwiftUI

struct HintBubble: View {
  enum Pointer {
    case trailing
    case up
  }

  let text: String
  var pointer: Pointer = .trailing
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  // why: a hint must NEVER be laid out inline with contested chrome — squeezed, it
  // degrades into letter-soup or "На…" truncation (the 2026-06-11 visual-review defect).
  // It always renders at its own intrinsic size; callers place it as a floating overlay.
  // At accessibility sizes the 2-line cap itself truncates — lift it and let the
  // bubble grow vertically instead.
  // why: D6 — the hint bubble floats over the live transcript, so it is legit glass chrome
  // (ADR 0013 rule 1). .regular glass (never .clear) over variable content; the text flips
  // from dark-on-white to WHITE because the glass renders as a dark material in the cockpit's
  // dark scheme (and degrades to a solid dark material under Reduce Transparency), keeping the
  // hint high-contrast in both modes. Intrinsic sizing (fixedSize) and the 2-line cap are
  // preserved — the floating-overlay rule from the 2026-06-11 letter-soup defect stands.
  private var bubbleText: some View {
    Text(text)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .multilineTextAlignment(.trailing)
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 230, alignment: .trailing)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .glassEffect(
        .regular,
        in: RoundedRectangle(cornerRadius: DspeechTheme.bubbleCornerRadius, style: .continuous))
  }

  var body: some View {
    Group {
      switch pointer {
      case .trailing:
        HStack(spacing: 5) {
          bubbleText
          tailDots
        }
      case .up:
        VStack(alignment: .trailing, spacing: 5) {
          tailDots
          bubbleText
        }
        .padding(.trailing, 22)
      }
    }
    .fixedSize()
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }

  // why: the pointer dots keep their solid-white fill (kept, not dropped): a tiny glass circle
  // each would be its own CABackdropLayer (ADR 0013 rule 4 violation) and would visually
  // dissolve against the glass bubble. Solid-white dots stay crisp against the dark transcript
  // and preserve the recognizable "hint pointing at the mic button" aesthetic.
  private var tailDots: some View {
    Group {
      switch pointer {
      case .trailing:
        Circle().fill(.white).frame(width: 9, height: 9)
        Circle().fill(.white).frame(width: 6, height: 6)
        Circle().fill(.white).frame(width: 3.5, height: 3.5)
      case .up:
        Circle().fill(.white).frame(width: 3.5, height: 3.5)
        Circle().fill(.white).frame(width: 6, height: 6)
        Circle().fill(.white).frame(width: 9, height: 9)
      }
    }
  }
}

struct InputLevelBar: View {
  let level: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.15))
        Capsule()
          .fill(DspeechTheme.accent)
          .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
      }
    }
  }
}

struct FilteredTransmissionsReviewSheet: View {
  let transmissions: [Transmission]
  let showTransmission: (Transmission) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if transmissions.isEmpty {
          ContentUnavailableView(
            String(localized: "No filtered transmissions"),
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(String(localized: "All filtered transmissions are already visible."))
          )
        } else {
          ForEach(transmissions) { transmission in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              VStack(alignment: .leading, spacing: 6) {
                Text(transmissionReasonLabel(for: transmission.classification))
                  .font(.caption.weight(.semibold))
                  // why: localized reason phrases (de "An anderes Luftfahrzeug gerichtet") overflow a
                  // single line at accessibility Dynamic Type; allow a 2-line wrap + more shrink so the
                  // badge never clips (caught by the de · AX-XL audit).
                  .lineLimit(2)
                  .minimumScaleFactor(0.6)
                  .foregroundStyle(DspeechTheme.filtered)
                  .accessibilityIdentifier("transmission-reason-badge")
                Text(transmission.text)
                  .font(.body.monospaced())
                Text(transmission.startedAt.formatted(date: .omitted, time: .standard))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              Button(String(localized: "Show")) {
                showTransmission(transmission)
              }
              .buttonStyle(.bordered)
              .controlSize(.regular)
              .accessibilityIdentifier("show-suppressed-segment")
            }
          }
        }
      }
      .navigationTitle(String(localized: "Filtered speech"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Done")) {
            dismiss()
          }
        }
      }
    }
    .accessibilityIdentifier("filtered-review-sheet")
    .preferredColorScheme(.dark)
  }
}

struct NoAnchorTransmissionHint: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      // why: no line limit — a capped hint truncated mid-word at default type size
      // (2026-06-12 visual review); fixedSize(vertical) grows the bubble instead.
      Text(text)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 230, alignment: .leading)

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white.opacity(0.85))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("no-anchor-hint-dismiss")
      .accessibilityLabel(String(localized: "Dismiss"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    // why: D6 — same glass migration as HintBubble; white text on .regular glass (dark
    // material in the dark scheme, solid under Reduce Transparency) keeps the no-anchor hint
    // legible over the transcript while it floats as chrome above the scrolling cards.
    .glassEffect(
      .regular,
      in: RoundedRectangle(cornerRadius: DspeechTheme.bubbleCornerRadius, style: .continuous)
    )
    // why: vertical-only — both-axes fixedSize measured the wrapped text against an
    // intrinsic single-line width and the background stayed 2 lines tall while the
    // text drew 4 (2026-06-12 visual review).
    .fixedSize(horizontal: false, vertical: true)
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
    .accessibilityIdentifier("no-anchor-hint")
  }
}

// why: the in-progress (partial) line must read as the SAME transcript, just live -- not a
// visually foreign cyan italic block. It mirrors TranscriptSegmentCard's layout and
// typography (white card, same large monospaced text) with only a small "LIVE" badge +
// cyan border to signal it is still being recognized.
struct PartialTranscriptCard: View {
  let text: String
  let isLandscape: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        // why: D14 Tier 2 (metadata) — LIVE is a status marker, not a state-critical reason,
        // so it recedes to an outline capsule. The cyan stays at full strength (not dimmed)
        // and the card's own cyan stroke reinforces "in progress", so the indicator still
        // reads as active despite the lighter badge weight. Monospaced kept: LIVE is a code.
        Label(String(localized: "LIVE"), systemImage: "waveform")
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(DspeechTheme.accent)
          .outlineBadge(tint: DspeechTheme.accent)
        Spacer()
      }
      Text(text)
        .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .transcriptCardChrome(stroke: DspeechTheme.accent.opacity(0.35))
    .transition(cardEntranceTransition(reduceMotion: reduceMotion))
    .accessibilityIdentifier("partial-transcript")
  }
}

struct TransmissionTranscriptCard: View {
  let transmission: Transmission
  let isLandscape: Bool
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      badgeRow
      Text(transmission.text)
        .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        // why: F14 — the tap-to-expand affordance is invisible to VoiceOver (a bare
        // onTapGesture exposes no action/hint). The transcript text is where VoiceOver lands,
        // so it carries the hint + a named custom action mirroring the tap toggle exactly, so a
        // VoiceOver user can reveal the timing detail without discovering the sighted-only tap.
        // Kept on the Text (not a combined element) so the utterance stays its own queryable
        // static-text node for the scripted-flow UI tests.
        .accessibilityHint(
          expanded
            ? String(localized: "Shows or hides the transmission's start and end time")
            : String(localized: "Shows the transmission's start and end time")
        )
        .accessibilityAction(named: Text(String(localized: "Show details"))) {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
        }
      if expanded { detailRow }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .transcriptCardChrome(stroke: .white.opacity(0.10))
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
    }
    .overlay(alignment: .topLeading) {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("transmission-card")
        .accessibilityLabel(String(localized: "Transmission"))
    }
    .transition(cardEntranceTransition(reduceMotion: reduceMotion))
  }

  private var badgeRow: some View {
    HStack(spacing: 8) {
      // why: D14 Tier 2 (metadata) — the locale code recedes to an outline capsule so the
      // Tier 1 reason badge is the visual anchor. Monospaced retained (D15): a 2-letter code
      // reads as a machine token, not prose, so it stays in the small "code" micro-register.
      Text(localeChipText)
        .font(.caption.monospaced().weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(.white.opacity(0.7))
        .outlineBadge(tint: .white)

      // why: D14 Tier 1 (state-critical) — the classification reason is a filled capsule.
      // D15: reason phrases are PROSE ("No callsign", "Urgent broadcast"), so they drop the
      // monospaced design and use SF, leaving the utterance text as the single mono register.
      Text(transmissionReasonLabel(for: transmission.classification))
        .font(.caption.weight(.bold))
        // why: see review-sheet badge — long localized reasons must wrap, not clip, at AX sizes.
        .lineLimit(2)
        .minimumScaleFactor(0.6)
        .foregroundStyle(reasonColor)
        .filledBadge(tint: reasonColor)
        .accessibilityIdentifier("transmission-reason-badge")

      Spacer(minLength: 0)
    }
  }

  private var detailRow: some View {
    HStack(spacing: 14) {
      Label(
        transmission.startedAt.formatted(date: .omitted, time: .standard),
        systemImage: "clock")
      if transmission.endedAt > transmission.startedAt {
        Text(transmission.endedAt.formatted(date: .omitted, time: .standard))
      }
      Spacer(minLength: 0)
    }
    // why: D15 — expanded metadata uses SF footnote with monospaced DIGITS only (tabular
    // time alignment) rather than the full monospaced font, so it sits below the utterance's
    // mono register instead of competing with it.
    .font(.footnote.monospacedDigit())
    .foregroundStyle(.white.opacity(0.85))
    .accessibilityIdentifier("transmission-details")
  }

  private var reasonColor: Color {
    switch transmission.classification {
    case .displayed(.callSignMatch), .displayed(.continuationOfRecentCall):
      return DspeechTheme.accent
    case .displayed(.noAnchorConfigured), .displayed(.insufficientEvidence):
      return DspeechTheme.filtered
    case .displayed(.urgencyBroadcast):
      return DspeechTheme.danger
    case .displayed(.nonPilotVoice):
      return DspeechTheme.success
    case .filtered:
      return DspeechTheme.filtered
    }
  }

  private var localeChipText: String {
    Locale.Language(identifier: transmission.localeIdentifier).languageCode?.identifier.uppercased()
      ?? transmission.localeIdentifier.uppercased()
  }
}

struct TranscriptSegmentCard: View {
  let segment: TranscriptSegment
  let translatedText: String?
  let isLandscape: Bool
  // why: PRD F2 -- the transcript honors Dynamic Type via a semantic monospaced text style
  // (.title / .title2) so the audit credits full Dynamic-Type support.
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      badgeRow
      transcriptText
      glossLine
      if expanded { detailRow }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .transcriptCardChrome(stroke: .white.opacity(0.10))
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
    }
    .transition(cardEntranceTransition(reduceMotion: reduceMotion))
    .accessibilityIdentifier("transcript-segment")
  }

  // why: PRD main view -- tapping a segment expands its details (timestamp + confidence).
  private var detailRow: some View {
    HStack(spacing: 14) {
      Label(
        segment.startedAt.formatted(date: .omitted, time: .standard),
        systemImage: "clock")
      if segment.confidence > 0 {
        Text(
          String(
            localized:
              "conf \(segment.confidence.formatted(.percent.precision(.fractionLength(0))))"
          )
        )
      }
      Spacer(minLength: 0)
    }
    // why: D15 — SF footnote with monospaced DIGITS (not the full monospaced font) keeps the
    // expanded metadata below the utterance's single mono register while preserving tabular
    // time/percent alignment.
    .font(.footnote.monospacedDigit())
    .foregroundStyle(.white.opacity(0.85))
    .accessibilityIdentifier("transcript-segment-details")
  }

  private var badgeRow: some View {
    HStack(spacing: 8) {
      // why: D14 Tier 2 (metadata) — source-language code recedes to an outline capsule;
      // monospaced kept (D15) because it is a 2-letter machine code, not prose.
      Text(segment.sourceLanguageCode.uppercased())
        .font(.caption.monospaced().weight(.bold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.7))
        .outlineBadge(tint: .white)

      if segment.source == .demo {
        // why: D14 Tier 2 — DEMO is a provenance marker (metadata), outline capsule.
        Text(String(localized: "DEMO"))
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(DspeechTheme.accent.opacity(0.9))
          .outlineBadge(tint: DspeechTheme.accent)
      }

      if segment.requiresVerification {
        // why: D14 Tier 1 — VERIFY is a state-critical trust signal, so it stays a filled
        // capsule (the heavier tier the eye lands on first). Monospaced code register kept.
        Text(String(localized: "VERIFY"))
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(DspeechTheme.filtered)
          .filledBadge(tint: DspeechTheme.filtered)
      }

      Spacer()

      // why: confidence 0 = unverified (e.g. a Stop-committed partial) -- hide the
      // meaningless "0%"; the VERIFY badge already carries the "unconfirmed" signal.
      // D14 Tier 2 metadata: dimmed, no capsule (bare trailing figure).
      if segment.confidence > 0 {
        Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.7))
      }
    }
  }

  @ViewBuilder
  private var transcriptText: some View {
    Text(segment.text)
      .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var glossLine: some View {
    if let translatedText, !translatedText.isEmpty {
      Text(translatedText)
        .font(.system(isLandscape ? .body : .title3, design: .rounded))
        .italic()
        .foregroundStyle(DspeechTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcript-translation")
    }
  }
}

private func transmissionReasonLabel(for classification: TransmissionClassification) -> String {
  switch classification {
  case .displayed(let reason):
    return displayReasonLabel(for: reason)
  case .filtered(let reason):
    return filterReasonLabel(for: reason)
  }
}

private func displayReasonLabel(for reason: TransmissionDisplayReason) -> String {
  switch reason {
  case .callSignMatch:
    return String(localized: "Own callsign")
  case .urgencyBroadcast:
    return String(localized: "Urgent broadcast")
  case .nonPilotVoice:
    return String(localized: "Dispatcher voice")
  case .noAnchorConfigured:
    return String(localized: "No callsign")
  case .insufficientEvidence:
    return String(localized: "Likely relevant")
  case .continuationOfRecentCall:
    return String(localized: "Follow-up call")
  }
}

private func filterReasonLabel(for reason: TransmissionFilterReason) -> String {
  switch reason {
  case .pilotVoice:
    return String(localized: "Pilot voice")
  case .addressedToOther:
    return String(localized: "Addressed to other aircraft")
  case .nonRelevant:
    return String(localized: "Not relevant")
  }
}

private enum TranscriptCardChrome {
  static let background = DspeechTheme.cardFill
  static let cornerRadius = DspeechTheme.cardCornerRadius
}

// why: D10 — new transcript/transmission cards fade in and rise a few points instead of
// popping into the LazyVStack. GATED exactly like every decorative motion in the app
// (MainControlsView `animatesGlassMorph`): under Reduce Motion OR the UI-test flag the
// transition collapses to .identity so it can never stall XCUITest quiescence. The actual
// insertion animation must be driven by a `withAnimation`/`.animation(value:)` around the
// ForEach in ContentView.transcriptArea — a `.transition` alone is inert without a driver.
private func cardEntranceTransition(reduceMotion: Bool) -> AnyTransition {
  if reduceMotion || DecorativeMotion.isDisabledForUITests {
    return .identity
  }
  return .opacity.combined(with: .offset(y: 10))
}

extension View {
  // why: D14 Tier 1 — state-critical badge: filled capsule (the current, heavier style) so
  // reason/VERIFY chips are the first thing the eye lands on in a stacked badge row.
  fileprivate func filledBadge(tint: Color) -> some View {
    padding(.horizontal, DspeechTheme.chipHorizontalPadding)
      .padding(.vertical, DspeechTheme.chipVerticalPadding)
      .background(tint.opacity(DspeechTheme.chipFillOpacity), in: Capsule())
  }

  // why: D14 Tier 2 — metadata badge: outline-only capsule (tinted stroke, no fill) so
  // locale/DEMO/LIVE chips visually recede beneath the filled Tier-1 badges. Callers dim the
  // foreground to complete the tier separation.
  fileprivate func outlineBadge(tint: Color) -> some View {
    padding(.horizontal, DspeechTheme.chipHorizontalPadding)
      .padding(.vertical, DspeechTheme.chipVerticalPadding)
      .overlay(Capsule().stroke(tint.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1))
  }
}

extension View {
  // why: the transcript-card chrome (dark fill + rounded rect + 1pt stroke) was copy-pasted across
  // PartialTranscriptCard / TransmissionTranscriptCard / TranscriptSegmentCard; one modifier keeps the
  // shared look from drifting. Only the stroke color differs per card.
  fileprivate func transcriptCardChrome(stroke: Color) -> some View {
    background(
      TranscriptCardChrome.background,
      in: RoundedRectangle(cornerRadius: TranscriptCardChrome.cornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: TranscriptCardChrome.cornerRadius, style: .continuous)
        .stroke(stroke, lineWidth: 1)
    }
  }
}
