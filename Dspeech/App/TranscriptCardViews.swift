import SwiftUI

struct HintBubble: View {
  enum Pointer {
    case trailing
    case up
  }

  let text: String
  var pointer: Pointer = .trailing

  // why: a hint must NEVER be laid out inline with contested chrome — squeezed, it
  // degrades into letter-soup or "На…" truncation (the 2026-06-11 visual-review defect).
  // It always renders at its own intrinsic size; callers place it as a floating overlay.
  private var bubbleText: some View {
    Text(text)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.black)
      .multilineTextAlignment(.trailing)
      .lineLimit(2)
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

struct SuppressedSegmentsReviewSheet: View {
  let segments: [TranscriptSegment]
  let indicator: (TranscriptSegment) -> ATCVoiceIndicator?
  let showSegment: (TranscriptSegment) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if segments.isEmpty {
          ContentUnavailableView(
            String(localized: "No filtered speech"),
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(String(localized: "All transcript segments are visible."))
          )
        } else {
          ForEach(segments) { segment in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              VStack(alignment: .leading, spacing: 6) {
                Text(reasonLabel(for: indicator(segment)))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.yellow)
                Text(segment.text)
                  .font(.body.monospaced())
                Text(segment.startedAt.formatted(date: .omitted, time: .standard))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              Button(String(localized: "Show")) {
                showSegment(segment)
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

  private func reasonLabel(for indicator: ATCVoiceIndicator?) -> String {
    switch indicator {
    case .pilotSuppressed:
      return String(localized: "Pilot")
    case .otherTrafficSuppressed:
      return String(localized: "Other traffic")
    case .noiseOrTooShortSuppressed:
      return String(localized: "Noise")
    case .dispatcherAddressedOwnCallSign:
      return String(localized: "Own callsign")
    case .dispatcherContinuation:
      return String(localized: "Continuation")
    case .probableDispatcher:
      return String(localized: "Dispatcher")
    case .mixedSpeakerCandidate:
      return String(localized: "Mixed speaker")
    case .filterOff:
      return String(localized: "Filter off")
    default:
      return String(localized: "Filtered")
    }
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
    .background(
      Color(red: 0.07, green: 0.08, blue: 0.10),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(.cyan.opacity(0.35), lineWidth: 1)
    }
    .accessibilityIdentifier("partial-transcript")
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
    .background(
      Color(red: 0.07, green: 0.08, blue: 0.10),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    }
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
