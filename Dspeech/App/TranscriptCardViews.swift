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
  private var bubbleText: some View {
    Text(text)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.black)
      .multilineTextAlignment(.trailing)
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 230, alignment: .trailing)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  var body: some View {
    Group {
      switch pointer {
      case .trailing:
        HStack(spacing: 5) {
          bubbleText
          Circle().fill(.white).frame(width: 9, height: 9)
          Circle().fill(.white).frame(width: 6, height: 6)
          Circle().fill(.white).frame(width: 3.5, height: 3.5)
        }
      case .up:
        VStack(alignment: .trailing, spacing: 5) {
          Circle().fill(.white).frame(width: 3.5, height: 3.5)
          Circle().fill(.white).frame(width: 6, height: 6)
          Circle().fill(.white).frame(width: 9, height: 9)
          bubbleText
        }
        .padding(.trailing, 22)
      }
    }
    .fixedSize()
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }
}

struct InputLevelBar: View {
  let level: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.15))
        Capsule()
          .fill(.cyan)
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
                  .foregroundStyle(.yellow)
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
        .foregroundStyle(.black)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 230, alignment: .leading)

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.black.opacity(0.78))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("no-anchor-hint-dismiss")
      .accessibilityLabel(String(localized: "Dismiss"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(String(localized: "LIVE"), systemImage: "waveform")
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(.cyan)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.cyan.opacity(0.16), in: Capsule())
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
    .transcriptCardChrome(stroke: .cyan.opacity(0.35))
    .accessibilityIdentifier("partial-transcript")
  }
}

struct TransmissionTranscriptCard: View {
  let transmission: Transmission
  let isLandscape: Bool
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      badgeRow
      Text(transmission.text)
        .font(.system(isLandscape ? .title2 : .title, design: .monospaced).weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
      if expanded { detailRow }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .transcriptCardChrome(stroke: .white.opacity(0.10))
    .contentShape(Rectangle())
    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    .overlay(alignment: .topLeading) {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("transmission-card")
        .accessibilityLabel(String(localized: "Transmission"))
    }
  }

  private var badgeRow: some View {
    HStack(spacing: 8) {
      Text(localeChipText)
        .font(.caption.monospaced().weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.12), in: Capsule())

      Text(transmissionReasonLabel(for: transmission.classification))
        .font(.caption.monospaced().weight(.bold))
        // why: see review-sheet badge — long localized reasons must wrap, not clip, at AX sizes.
        .lineLimit(2)
        .minimumScaleFactor(0.6)
        .foregroundStyle(reasonColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(reasonColor.opacity(0.14), in: Capsule())
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
    .font(.caption.monospacedDigit())
    .foregroundStyle(.white.opacity(0.85))
    .accessibilityIdentifier("transmission-details")
  }

  private var reasonColor: Color {
    switch transmission.classification {
    case .displayed(.callSignMatch), .displayed(.continuationOfRecentCall):
      return .cyan
    case .displayed(.noAnchorConfigured), .displayed(.insufficientEvidence):
      return .yellow
    case .displayed(.urgencyBroadcast):
      return .red
    case .displayed(.nonPilotVoice):
      return .green
    case .filtered:
      return .yellow
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
    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
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
    .font(.caption.monospacedDigit())
    .foregroundStyle(.white.opacity(0.85))
    .accessibilityIdentifier("transcript-segment-details")
  }

  private var badgeRow: some View {
    HStack(spacing: 8) {
      Text(segment.sourceLanguageCode.uppercased())
        .font(.caption.monospaced().weight(.bold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.12), in: Capsule())

      if segment.source == .demo {
        Text(String(localized: "DEMO"))
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(.cyan.opacity(0.9))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.cyan.opacity(0.14), in: Capsule())
      }

      if segment.requiresVerification {
        Text(String(localized: "VERIFY"))
          .font(.caption.monospaced().weight(.bold))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(.yellow)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.yellow.opacity(0.16), in: Capsule())
      }

      Spacer()

      // why: confidence 0 = unverified (e.g. a Stop-committed partial) -- hide the
      // meaningless "0%"; the VERIFY badge already carries the "unconfirmed" signal.
      if segment.confidence > 0 {
        Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.85))
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
        .foregroundStyle(.cyan)
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
  static let background = Color(red: 0.07, green: 0.08, blue: 0.10)
  static let cornerRadius: CGFloat = 18
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
