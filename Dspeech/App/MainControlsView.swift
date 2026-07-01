import SwiftUI
import UIKit

struct MainControlBar: View {
  let isLandscape: Bool
  let privacyMode: PrivacyMode
  let routeHealth: RouteHealth
  let isSessionActive: Bool
  let openHistory: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: isLandscape ? 6 : 10) {
        Text("Dspeech")
          .font(.system(isLandscape ? .title3 : .title2, design: .rounded).weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .layoutPriority(1)
          .accessibilityIdentifier("app-title")

        // why: the privacy/route chips are mandatory cockpit chrome (ADR 0002) — they may
        // scale via their own minimumScaleFactor but must never be compressed into
        // letter-wrap fragments by a neighboring hint bubble. The original both-axes
        // fixedSize made the column incompressible at accessibility type sizes and
        // shoved the history/settings buttons off the right screen edge, and pure
        // compression ellipsized the MIC chip (2026-06-12 visual review): side-by-side
        // chips when they fit at intrinsic size, stacked vertically when they don't.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            PrivacyBadge(mode: privacyMode)
            RouteHealthChip(health: routeHealth)
          }
          .fixedSize()
          VStack(alignment: .leading, spacing: 6) {
            PrivacyBadge(mode: privacyMode)
            RouteHealthChip(health: routeHealth)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .layoutPriority(2)

      Spacer(minLength: 8)

      historyButton
      settingsButton
    }
  }

  private var historyButton: some View {
    let diameter: CGFloat = isLandscape ? 46 : 56
    return Button(action: openHistory) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: isLandscape ? 21 : 25, weight: .semibold))
        .foregroundStyle(.white.opacity(isSessionActive ? 0.35 : 0.9))
        .frame(width: diameter, height: diameter)
        .background(
          Circle()
            .fill(.white.opacity(isSessionActive ? 0.06 : 0.12))
        )
        .overlay(
          Circle()
            .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .contentShape(Circle())
    .disabled(isSessionActive)
    .accessibilityIdentifier("session-history-button")
    .accessibilityLabel(String(localized: "Session history"))
  }

  private var settingsButton: some View {
    // why: sized to span the left column (title top -> LOCAL badge bottom) per the
    // requested proportion.
    let diameter: CGFloat = isLandscape ? 46 : 56
    return Button(action: openSettings) {
      Image(systemName: "gearshape.fill")
        .font(.system(size: isLandscape ? 22 : 26, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: diameter, height: diameter)
        .background(
          Circle()
            .fill(.white.opacity(0.12))
        )
        .overlay(
          Circle()
            .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .contentShape(Circle())
    .accessibilityIdentifier("settings-button")
    .accessibilityLabel(String(localized: "Settings"))
  }
}

struct FloatingStartControls: View {
  let isLandscape: Bool
  let maxWidth: CGFloat?
  let showHints: Bool
  let isStopVisible: Bool
  let disabled: Bool
  let action: () -> Void

  var body: some View {
    // why: at accessibility type sizes hint+button exceed the screen width and the
    // overflow pushed the PRIMARY start button half off-screen (2026-06-12 visual
    // review); ViewThatFits drops to a trailing-aligned vertical stack instead.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        hintIfNeeded
        StartButton(isStopVisible: isStopVisible, disabled: disabled, action: action)
      }
      VStack(alignment: .trailing, spacing: 10) {
        hintIfNeeded
        StartButton(isStopVisible: isStopVisible, disabled: disabled, action: action)
      }
    }
    .frame(maxWidth: maxWidth ?? .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .padding(.trailing, isLandscape ? 16 : 18)
    .padding(.bottom, isLandscape ? 10 : 16)
  }

  @ViewBuilder
  private var hintIfNeeded: some View {
    if showHints {
      HintBubble(text: String(localized: "Tap to start recognition"))
    }
  }
}

struct BottomLeftControls: View {
  let isLandscape: Bool
  let maxWidth: CGFloat?
  let canClearTranscriptView: Bool
  let error: String?
  let clearTranscript: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if canClearTranscriptView {
        Button(String(localized: "Clear"), action: clearTranscript)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white.opacity(0.85))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
          .accessibilityIdentifier("clear-button")
      }
      if let error {
        LiveFailureBanner(error: error)
      }
      // why: reserve the bottom-trailing column so the error text never wraps under the
      // floating mic button (the obscured/unreadable banner the audit's elementDetection
      // catches); the banner stays left of the button and grows upward.
      Spacer(minLength: 84)
    }
    .frame(maxWidth: maxWidth ?? .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .padding(.leading, isLandscape ? 16 : 18)
    .padding(.bottom, isLandscape ? 16 : 24)
  }
}

struct PrivacyBadge: View {
  let mode: PrivacyMode

  // why: tint + VoiceOver label derive from whether the mode keeps audio on-device, not a
  // hardcoded green/"On-device" — so a future off-device mode can't render green or be
  // mislabeled "On-device processing" (ADR 0002 demands the badge tell the truth).
  private var tint: Color {
    mode.sendsAudioOffDevice ? DspeechTheme.warning : DspeechTheme.success
  }

  private var voiceOverLabel: String {
    mode.sendsAudioOffDevice
      ? String(localized: "Sends audio off device")
      : String(localized: "On-device processing")
  }

  var body: some View {
    Text(mode.badgeText)
      .font(.caption2.weight(.bold).monospaced())
      .lineLimit(1)
      .minimumScaleFactor(0.65)
      .foregroundStyle(tint)
      .padding(.horizontal, DspeechTheme.chipHorizontalPadding)
      .padding(.vertical, DspeechTheme.chipVerticalPadding)
      .background(tint.opacity(DspeechTheme.chipFillOpacity), in: Capsule())
      .overlay(
        Capsule().stroke(tint.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
      )
      .accessibilityIdentifier("privacy-badge")
      .accessibilityLabel(voiceOverLabel)
  }
}

struct RouteHealthChip: View {
  let health: RouteHealth

  private var tint: Color {
    switch health {
    case .suitableExternal: return DspeechTheme.success
    case .cautionBuiltIn: return DspeechTheme.warning
    case .unknownExternal, .unsuitableOutputOnly: return DspeechTheme.filtered
    case .noInput: return DspeechTheme.danger
    }
  }

  private var icon: String {
    switch health {
    case .suitableExternal: return "cable.connector"
    case .cautionBuiltIn: return "iphone"
    case .unknownExternal: return "questionmark.circle"
    case .unsuitableOutputOnly: return "speaker.wave.2"
    case .noInput: return "mic.slash"
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2.weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
      Text(health.shortLabel)
        .font(.caption2.weight(.bold).monospaced())
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, DspeechTheme.chipHorizontalPadding)
    .padding(.vertical, DspeechTheme.chipVerticalPadding)
    .background(tint.opacity(DspeechTheme.chipFillOpacity), in: Capsule())
    .overlay(
      Capsule().stroke(tint.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
    )
    .accessibilityIdentifier("route-health-chip")
    .accessibilityLabel(String(localized: "Capture source: \(health.displayLabel)"))
  }
}

// why: XCUITest's `performAccessibilityAudit` and element queries require the app to reach an
// idle state; an infinite `repeatForever` decorative animation keeps the run loop perpetually
// "busy" and intermittently destabilizes audits and hit-testing on the hosted CI simulator.
// Honoring reduce-motion is also a genuine accessibility win (continuous motion is exactly what
// that setting asks us to suppress); the launch flag lets UI/audit tests force the same stable
// state without depending on a device-level setting XCUITest cannot toggle.
enum DecorativeMotion {
  static let isDisabledForUITests: Bool =
    CommandLine.arguments.contains("-dspeech.uitest.reduce-animations")
}

private struct StartButton: View {
  let isStopVisible: Bool
  let disabled: Bool
  let action: () -> Void
  @State private var glowAngle = 0.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var animatesGlow: Bool {
    !reduceMotion && !DecorativeMotion.isDisabledForUITests
  }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(isStopVisible ? DspeechTheme.danger.opacity(0.85) : Color.gray.opacity(0.55))
        if !isStopVisible {
          // why: a glow that travels around the rim (rotating angular gradient) plus a
          // cyan dashed border, to pull attention to the idle Start control.
          Circle()
            .stroke(
              AngularGradient(
                gradient: Gradient(colors: [
                  DspeechTheme.accent.opacity(0), DspeechTheme.accent,
                  DspeechTheme.accent.opacity(0),
                ]),
                center: .center),
              lineWidth: 4
            )
            .blur(radius: 5)
            .rotationEffect(.degrees(glowAngle))
          Circle()
            .strokeBorder(DspeechTheme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
        }
        Image(systemName: isStopVisible ? "stop.fill" : "mic.fill")
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(width: 64, height: 64)
      .opacity(disabled ? 0.45 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityIdentifier(isStopVisible ? "stop-button" : "start-button")
    .accessibilityLabel(isStopVisible ? String(localized: "Stop") : String(localized: "Start"))
    .onAppear {
      guard animatesGlow else { return }
      withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
        glowAngle = 360
      }
    }
  }
}

private struct LiveFailureBanner: View {
  let error: String

  private var canOpenSettings: Bool {
    error == "speech-permission-denied" || error == "microphone-permission-denied"
      || error == "permission-request-timed-out"
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(RecognitionFailureText.userFacing(error))
        .fixedSize(horizontal: false, vertical: true)
      if canOpenSettings {
        Button {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        } label: {
          Text(String(localized: "Open Settings"))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.black.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-settings-button")
      }
    }
    .font(.caption)
    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.3))
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    .accessibilityIdentifier("error-banner")
  }
}
