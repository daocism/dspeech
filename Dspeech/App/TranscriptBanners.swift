import SwiftUI

struct RouteBanner: View {
  let message: String
  let canStart: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: canStart ? "exclamationmark.triangle.fill" : "mic.slash.fill")
        .font(.footnote.weight(.semibold))
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .foregroundStyle(canStart ? Color.orange : Color.red)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      (canStart ? Color.orange : Color.red).opacity(0.14),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke((canStart ? Color.orange : Color.red).opacity(0.4), lineWidth: 1)
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
      Text(String(localized: "Listening stopped while the app was in the background."))
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("background-stop-dismiss")
      .accessibilityLabel(String(localized: "Dismiss background stop notice"))
    }
    .foregroundStyle(Color.white.opacity(0.86))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
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
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("persistence-failure-dismiss")
      .accessibilityLabel(String(localized: "Dismiss transcript storage warning"))
    }
    .foregroundStyle(Color.orange)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
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
      Text(message)
        .font(.footnote.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onOpenSettings) {
        Text(String(localized: "Translation settings"))
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
          .padding(.horizontal, 10)
          .frame(minHeight: 32)
          .background(.black.opacity(0.32), in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("translation-settings-action")
    }
    .foregroundStyle(Color.cyan)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.cyan.opacity(0.38), lineWidth: 1)
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
      .foregroundStyle(.yellow)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(.yellow.opacity(0.14), in: Capsule())
      .overlay {
        Capsule().stroke(.yellow.opacity(0.42), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("filtered-transmissions-pill")
    .accessibilityLabel(String(localized: "\(count) filtered transmissions"))
  }
}
