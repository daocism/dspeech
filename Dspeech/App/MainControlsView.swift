import SwiftUI
import UIKit

struct MainControlBar: View {
  let isLandscape: Bool
  let privacyMode: PrivacyMode
  let routeHealth: RouteHealth
  let isSessionActive: Bool
  let openHistory: () -> Void
  let openSettings: () -> Void

  // why: one namespace + one GlassEffectContainer for the whole bar cluster (ADR 0013 rule 4)
  // so the history/settings circles and the privacy/route capsules render in a single pass
  // (each independent glassEffect is otherwise its own CABackdropLayer). Small container
  // spacing keeps the distinct shapes from blending into one blob at rest — the Spacer and
  // inter-chip gaps stay larger than the merge distance.
  @Namespace private var glassNamespace

  var body: some View {
    GlassEffectContainer(spacing: 4) {
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
              PrivacyBadge(mode: privacyMode, glassNamespace: glassNamespace)
              RouteHealthChip(health: routeHealth)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
              PrivacyBadge(mode: privacyMode, glassNamespace: glassNamespace)
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
  }

  private var historyButton: some View {
    let diameter: CGFloat = isLandscape ? 46 : 56
    return Button(action: openHistory) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: isLandscape ? 21 : 25, weight: .semibold))
        .foregroundStyle(.white.opacity(isSessionActive ? 0.35 : 0.9))
        .frame(width: diameter, height: diameter)
        // why: .regular glass over the live transcript (never .clear) keeps the icon legible
        // against scrolling content; the white hairline stroke preserves the edge the flat
        // fill used to give. Disabled state dims via the icon opacity, not a separate fill.
        .glassEffect(.regular, in: Circle())
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
        .glassEffect(.regular, in: Circle())
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
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 10) {
        if canClearTranscriptView {
          Button(String(localized: "Clear"), action: clearTranscript)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            // why: glass backing for the floating Clear control (D5) — the label used to
            // float bare over the transcript; a .regular glass capsule gives it a legible
            // surface without an opaque footer strip. Horizontal padding gives the capsule
            // width; contentShape keeps the whole capsule (not just the label) tappable.
            .glassEffect(.regular, in: Capsule())
            .contentShape(Capsule())
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
}

struct PrivacyBadge: View {
  let mode: PrivacyMode
  let glassNamespace: Namespace.ID

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
    // why: NEUTRAL .regular glass (no tint) is a hard-gate legibility decision (CLAUDE.md
    // rule 4 / ADR 0002). Tinting the glass with the same green/orange as the label would
    // wash the tinted text into its own background; a neutral dark glass maximizes the
    // contrast of the coloured LOCAL/CLOUD text. Under Reduce Transparency the system
    // degrades .regular to a SOLID dark material (dark scheme) — the coloured text and the
    // tinted stroke both stay high-contrast against it, so the badge is legible in BOTH
    // transparency modes. The tinted stroke carries the colour identity onto the glass.
    Text(mode.badgeText)
      .font(.caption2.weight(.bold).monospaced())
      .lineLimit(1)
      .minimumScaleFactor(0.65)
      .foregroundStyle(tint)
      .padding(.horizontal, DspeechTheme.chipHorizontalPadding)
      .padding(.vertical, DspeechTheme.chipVerticalPadding)
      .glassEffect(.regular, in: Capsule())
      .overlay(
        Capsule().stroke(tint.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
      )
      // why: stable identity so a LOCAL <-> CLOUD change morphs the capsule (width shifts
      // with the label) inside the bar's GlassEffectContainer instead of popping. The morph
      // is a matched-geometry transition, which the system suppresses under Reduce Motion.
      .glassEffectID("privacy-badge", in: glassNamespace)
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
    // why: neutral .regular glass + tinted stroke, matching PrivacyBadge — the route colour
    // reads through the icon + text, not the glass fill (legibility over the live transcript).
    .glassEffect(.regular, in: Capsule())
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
  // why: glassEffectID needs a GlassEffectContainer + Namespace ancestor. The Start control is
  // standalone (its own floating cluster), so it owns a single-element container of its own.
  @Namespace private var glassNamespace

  private var animatesGlow: Bool {
    !reduceMotion && !DecorativeMotion.isDisabledForUITests
  }

  // why: .interactive() glass and the tint morph keep the render loop lively enough that
  // XCUITest quiescence-waits stall past the scripted engine's partial window (caught by
  // testScriptedEngineShowsPartialFinalAndClearFlow) — gate them exactly like the glow.
  private var animatesGlassMorph: Bool {
    !reduceMotion && !DecorativeMotion.isDisabledForUITests
  }

  private var startStopGlass: Glass {
    let tinted = Glass.regular.tint(glassTint)
    return animatesGlassMorph ? tinted.interactive() : tinted
  }

  // why: primary-action prominence via tint on .regular glass — accent (cyan) invites the
  // Start tap, danger (red) signals the Stop affordance. The tint replaces the old flat
  // gray/red fills so the control reads as one generation with the iOS 26 system chrome.
  private var glassTint: Color {
    isStopVisible ? DspeechTheme.danger : DspeechTheme.accent
  }

  var body: some View {
    GlassEffectContainer {
      Button(action: action) {
        ZStack {
          if !isStopVisible {
            // why: a glow that travels around the rim (rotating angular gradient) plus a
            // cyan dashed border, to pull attention to the idle Start control. Rendered OVER
            // the glass disk (the flat base Circle().fill is gone — the glass provides it).
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
        // why: interactive .regular glass — the primary control reacts to touch like system
        // glass buttons; .regular (never .clear) keeps the white icon legible over the live
        // transcript. Circle() shape gives the round hit/render surface directly, so no
        // .buttonBorderShape(.circle)+.clipShape dance (that's only for .glassProminent style).
        .glassEffect(startStopGlass, in: Circle())
        // why: stable identity so start<->stop morphs the glass (tint shift) inside the
        // container rather than popping. matchedGeometry morph is auto-suppressed under
        // Reduce Motion; the value animation below is likewise nil'd there.
        .glassEffectID("start-stop-button", in: glassNamespace)
        .animation(animatesGlassMorph ? .smooth(duration: 0.3) : nil, value: isStopVisible)
        .opacity(disabled ? 0.45 : 1)
      }
      .buttonStyle(.plain)
      .contentShape(Circle())
      .disabled(disabled)
      .accessibilityIdentifier(isStopVisible ? "stop-button" : "start-button")
      .accessibilityLabel(isStopVisible ? String(localized: "Stop") : String(localized: "Start"))
      // why: haptic keyed to the listening-state change, NOT the tap — a tap that fails
      // permission never flips isStopVisible into a stable Stop, so a failed start does not
      // emit the "started" impact. .impact is neutral (not .success) so any transient edge
      // never sounds like confirmation of success.
      .sensoryFeedback(.impact, trigger: isStopVisible)
      .onAppear {
        guard animatesGlow else { return }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
          glowAngle = 360
        }
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
            // why: glass capsule instead of flat black so the inner action reads as a control
            // on the glass banner, not a black rectangle floating on it.
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-settings-button")
      }
    }
    .font(.caption)
    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.3))
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    // why: D5 — .regular glass surface with a warning-tinted border replaces the flat
    // black 0.55 fill. The warm amber text literal is kept for now; the tinted stroke keys
    // the banner to the warning semantic. Under Reduce Transparency .regular degrades to a
    // solid dark material and the amber text stays high-contrast against it.
    .glassEffect(.regular, in: .rect(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .stroke(DspeechTheme.warning.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
    )
    .accessibilityIdentifier("error-banner")
  }
}
