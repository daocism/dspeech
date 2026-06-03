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
  // why: the hero icon scales with the user's Dynamic Type setting instead of a fixed 64pt.
  @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

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
        String(localized: "Audio and transcripts stay on this iPhone. Nothing leaves your device."),
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
    ZStack {
      LinearGradient(
        colors: [Color.black, Color(red: 0.03, green: 0.06, blue: 0.10)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 24) {
        TabView(selection: $selection) {
          ForEach(Self.cards) { card in
            cardView(card).tag(card.id)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))

        Button(action: advance) {
          Text(isLastCard ? String(localized: "Get started") : String(localized: "Next"))
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.cyan.opacity(0.85)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isLastCard ? "onboarding-done-button" : "onboarding-next-button")
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
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

  private func cardView(_ card: OnboardingCard) -> some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: card.systemImage)
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(.cyan)
      Text(card.title)
        .font(.system(.title, design: .rounded).weight(.bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      Text(card.message)
        .font(.body.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(card.accessibilityIdentifier)
  }
}

#Preview {
  OnboardingView(onComplete: {})
}
