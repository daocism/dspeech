import SwiftUI

struct OnboardingCard: Identifiable {
  let id: Int
  let systemImage: String
  let title: String
  let message: String
  let accessibilityIdentifier: String
}

struct OnboardingView: View {
  let onComplete: () -> Void
  @State private var selection = 0
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // why: the hero icon scales with the user's Dynamic Type setting instead of a fixed 64pt.
  @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

  // why: mirror the MainControlsView StartButton glass idiom — .interactive() glass keeps the
  // render loop lively, which stalls XCUITest quiescence waits, so gate it exactly like the live
  // control chrome (Reduce Motion OR the UI-test animation-disable flag). ADR 0013 rules 3 + 6.
  private var animatesGlassMorph: Bool {
    !reduceMotion && !DecorativeMotion.isDisabledForUITests
  }

  // why: accent-tinted .regular glass (never .clear) — the floating CTA reads as one generation with
  // the iOS 26 system chrome; .regular keeps the black label legible over the dark gradient backdrop.
  private var ctaGlass: Glass {
    let tinted = Glass.regular.tint(DspeechTheme.accent)
    return animatesGlassMorph ? tinted.interactive() : tinted
  }

  static let cards: [OnboardingCard] = [
    OnboardingCard(
      id: 0,
      systemImage: "antenna.radiowaves.left.and.right",
      title: String(localized: "Receive-only"),
      message:
        String(
          localized:
            "Dspeech doesn't transmit on air or send anything over the radio. The app only listens and shows text."
        ),
      accessibilityIdentifier: "onboarding-card-receive-only"
    ),
    OnboardingCard(
      id: 1,
      systemImage: "lock.shield",
      title: String(localized: "Local by default"),
      message:
        String(localized: "Audio and transcripts stay on this device. Nothing leaves your device."),
      accessibilityIdentifier: "onboarding-card-local-first"
    ),
    OnboardingCard(
      id: 2,
      systemImage: "cable.connector",
      title: String(localized: "Connect an input for accuracy"),
      message:
        String(
          localized:
            "Use the built-in microphone to try it out. For the cockpit, connect a wired input (USB-C / TRRS)."
        ),
      accessibilityIdentifier: "onboarding-card-wire-for-accuracy"
    ),
  ]

  private var isLastCard: Bool { selection == Self.cards.count - 1 }

  var body: some View {
    GeometryReader { geometry in
      let useScrollablePages = shouldUseScrollablePages(size: geometry.size)

      ZStack {
        LinearGradient(
          colors: [DspeechTheme.backgroundTop, DspeechTheme.backgroundBottom],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack(spacing: 24) {
          TabView(selection: $selection) {
            ForEach(Self.cards) { card in
              cardView(card, scrollable: useScrollablePages).tag(card.id)
            }
          }
          .tabViewStyle(.page(indexDisplayMode: .always))
          .indexViewStyle(.page(backgroundDisplayMode: .always))

          GlassEffectContainer {
            Button(action: advance) {
              Text(isLastCard ? String(localized: "Get started") : String(localized: "Next"))
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .glassEffect(ctaGlass, in: Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .accessibilityIdentifier(
              isLastCard ? "onboarding-done-button" : "onboarding-next-button"
            )
          }
          .padding(.horizontal, 32)
          .padding(.bottom, 24)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private func advance() {
    if isLastCard {
      onComplete()
    } else {
      withAnimation { selection += 1 }
    }
  }

  private func shouldUseScrollablePages(size: CGSize) -> Bool {
    dynamicTypeSize.isAccessibilitySize || size.height < 560
  }

  @ViewBuilder
  private func cardView(_ card: OnboardingCard, scrollable: Bool) -> some View {
    if scrollable {
      ScrollView {
        cardContent(card, includeSpacers: false)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 36)
      }
      .accessibilityIdentifier(card.accessibilityIdentifier)
    } else {
      cardContent(card, includeSpacers: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(card.accessibilityIdentifier)
    }
  }

  @ViewBuilder
  private func cardContent(_ card: OnboardingCard, includeSpacers: Bool) -> some View {
    VStack(spacing: 20) {
      if includeSpacers { Spacer() }
      Image(systemName: card.systemImage)
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(DspeechTheme.accent)
      Text(card.title)
        .font(.system(.title, design: .rounded).weight(.bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      Text(card.message)
        .font(.body.weight(.medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 32)
      if includeSpacers { Spacer() }
    }
  }
}

#Preview {
  OnboardingView(onComplete: {})
}
