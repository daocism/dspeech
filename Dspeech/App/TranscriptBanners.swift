import SwiftUI

struct RouteBanner: View {
  let message: String
  let canStart: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: canStart ? "exclamationmark.triangle.fill" : "mic.slash.fill")
        .font(.footnote.weight(.semibold))
        .accessibilityHidden(true)
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .foregroundStyle(canStart ? DspeechTheme.warning : DspeechTheme.danger)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    // why: D7 — floating status chrome over the live transcript → .regular glass (ADR 0013
    // rule 1/3), replacing the flat color.opacity(0.14) fill. Per-severity tint lives on the
    // stroke + the coloured text, NOT the glass fill (a tinted glass would wash the same-hue
    // text into it). Under Reduce Transparency .regular degrades to a solid dark material and
    // the warning/danger text + stroke stay high-contrast.
    .glassEffect(
      .regular, in: .rect(cornerRadius: DspeechTheme.bannerCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DspeechTheme.bannerCornerRadius, style: .continuous)
        .stroke(
          (canStart ? DspeechTheme.warning : DspeechTheme.danger)
            .opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
    }
    .accessibilityIdentifier("route-banner")
  }
}

struct BackgroundStopNoticeBanner: View {
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "info.circle.fill")
        .font(.footnote.weight(.semibold))
        .accessibilityHidden(true)
      Text(String(localized: "Listening stopped while the app was in the background."))
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("background-stop-dismiss")
      .accessibilityLabel(String(localized: "Dismiss background stop notice"))
    }
    .foregroundStyle(Color.white.opacity(0.86))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    // why: D7 — neutral informational banner → neutral .regular glass with a plain white
    // hairline (no severity tint; this notice is not an error). Matches the glass idiom of
    // the other floating banners.
    .glassEffect(.regular, in: .rect(cornerRadius: DspeechTheme.bannerCornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DspeechTheme.bannerCornerRadius)
        .stroke(Color.white.opacity(0.26), lineWidth: 1)
    }
    .accessibilityIdentifier("background-stop-banner")
  }
}

struct PersistenceFailureBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.footnote.weight(.semibold))
        .accessibilityHidden(true)
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("persistence-failure-dismiss")
      .accessibilityLabel(String(localized: "Dismiss transcript storage warning"))
    }
    .foregroundStyle(DspeechTheme.warning)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    // why: D7 — warning-severity glass banner; tint on stroke + text only (see RouteBanner).
    .glassEffect(.regular, in: .rect(cornerRadius: DspeechTheme.bannerCornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DspeechTheme.bannerCornerRadius)
        .stroke(DspeechTheme.warning.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
    }
    .accessibilityIdentifier("persistence-failure-banner")
  }
}

struct TranslationFailureBanner: View {
  let message: String
  let isUnavailable: Bool
  let onOpenSettings: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(
        systemName: isUnavailable
          ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.footnote.weight(.semibold))
      .accessibilityHidden(true)
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onOpenSettings) {
        Text(String(localized: "Translation settings"))
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          // why: D7 — inner action reads as a control ON the glass banner, so it gets its own
          // .regular glass capsule (mirrors LiveFailureBanner's Open-Settings button) instead
          // of a flat black rect floating on the glass.
          .glassEffect(.regular, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("translation-settings-action")
    }
    .foregroundStyle(DspeechTheme.accent)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    // why: D7 — accent-tinted glass banner; tint on stroke + text only (see RouteBanner).
    .glassEffect(.regular, in: .rect(cornerRadius: DspeechTheme.bannerCornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DspeechTheme.bannerCornerRadius)
        .stroke(DspeechTheme.accent.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
    }
    .accessibilityIdentifier("translation-failure-banner")
  }
}

struct FilteredCountPill: View {
  let count: Int
  let onReview: () -> Void

  var body: some View {
    Button(action: onReview) {
      Label(
        String(localized: "\(count) filtered"),
        systemImage: "line.3.horizontal.decrease.circle.fill"
      )
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .fixedSize()
      .foregroundStyle(DspeechTheme.filtered)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      // why: D8 — the filtered-count pill floats over the transcript → .regular glass capsule
      // with a filtered-yellow tinted stroke, replacing the flat yellow.opacity(0.14) fill.
      // Tint stays on the stroke + text so the yellow label reads against the glass.
      .glassEffect(.regular, in: Capsule())
      .overlay {
        Capsule()
          .stroke(DspeechTheme.filtered.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("filtered-transmissions-pill")
    .accessibilityLabel(String(localized: "\(count) filtered transmissions"))
  }
}
