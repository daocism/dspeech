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

  static let cards: [OnboardingCard] = [
    OnboardingCard(
      id: 0,
      systemImage: "antenna.radiowaves.left.and.right",
      title: "Только приём",
      message:
        "Dspeech не выходит в эфир и ничего не передаёт по радио. Приложение только слушает и показывает текст.",
      accessibilityIdentifier: "onboarding-card-receive-only"
    ),
    OnboardingCard(
      id: 1,
      systemImage: "lock.shield",
      title: "Локально по умолчанию",
      message:
        "Аудио и расшифровки остаются на этом iPhone. Ничего не покидает устройство.",
      accessibilityIdentifier: "onboarding-card-local-first"
    ),
    OnboardingCard(
      id: 2,
      systemImage: "cable.connector",
      title: "Подключите вход для точности",
      message:
        "Встроенный микрофон — чтобы попробовать. Для кокпита подключите проводной вход (USB-C / TRRS).",
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
          Text(isLastCard ? "Начать" : "Далее")
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
        .font(.system(size: 64, weight: .semibold))
        .foregroundStyle(.cyan)
      Text(card.title)
        .font(.system(size: 28, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      Text(card.message)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
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
