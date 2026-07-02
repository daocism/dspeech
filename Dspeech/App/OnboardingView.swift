import SwiftUI

struct OnboardingCard: Identifiable {
  let id: Int
  let systemImage: String
  let title: String
  let message: String
  let accessibilityIdentifier: String
  // why: H4 — the safety advisory card leads with the theme warning tint so it reads as a caution,
  // not brand chrome; the informational cards keep the accent. Defaulted so existing cards are terse.
  var tint: Color = DspeechTheme.accent
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

  // why: H4 — the safety advisory is card 0 so it is the FIRST thing a first-run pilot reads, before
  // any capability framing: the transcript is an advisory aid that can be wrong and never replaces
  // listening to the radio/ATC. The informational cards follow. ids stay contiguous 0…3 so the paged
  // `selection` tag and `isLastCard` (selection == count - 1) advance correctly.
  static let cards: [OnboardingCard] = [
    OnboardingCard(
      id: 0,
      systemImage: "exclamationmark.triangle",
      title: String(localized: "Advisory only"),
      message:
        String(
          localized:
            "Transcripts can be wrong or incomplete. Dspeech is an advisory aid and never replaces listening to the radio or ATC instructions."
        ),
      accessibilityIdentifier: "onboarding-card-advisory",
      tint: DspeechTheme.warning
    ),
    OnboardingCard(
      id: 1,
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
      id: 2,
      systemImage: "lock.shield",
      title: String(localized: "Local by default"),
      message:
        String(localized: "Audio and transcripts stay on this device. Nothing leaves your device."),
      accessibilityIdentifier: "onboarding-card-local-first"
    ),
    OnboardingCard(
      id: 3,
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
    } else if animatesGlassMorph {
      withAnimation { selection += 1 }
    } else {
      selection += 1
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
        .foregroundStyle(card.tint)
      Text(card.title)
        .font(.system(.title, design: .rounded).weight(.bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        // why: at AX-XL the longer localized titles (German "Nur zur Orientierung") wrap; without
        // fixedSize the title is clipped instead of growing vertically. Horizontal margin lets it
        // wrap inside the card rather than at the screen edge (matches the message row).
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
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
