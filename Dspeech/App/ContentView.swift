import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptDemoViewModel.demo
    @State private var showTranslation: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.03, green: 0.06, blue: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: isLandscape ? 8 : 12) {
                    controlBar(isLandscape: isLandscape)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: isLandscape ? 10 : 12) {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentCard(
                                    segment: segment,
                                    showTranslation: showTranslation,
                                    isLandscape: isLandscape
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, isLandscape ? 16 : 18)
                .padding(.top, isLandscape ? 6 : 10)
                .padding(.bottom, isLandscape ? 8 : 14)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private func controlBar(isLandscape: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Dspeech")
                .font(.system(size: isLandscape ? 22 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityIdentifier("app-title")

            Spacer()

            Toggle(isOn: $showTranslation) {
                Text("Перевод")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .tint(.cyan)
            .fixedSize()
            .accessibilityIdentifier("translation-toggle")
        }
    }
}

private struct TranscriptSegmentCard: View {
    let segment: TranscriptSegment
    let showTranslation: Bool
    let isLandscape: Bool

    private var hasTranslation: Bool {
        showTranslation && segment.translatedText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            badgeRow
            body(hasTranslation: hasTranslation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 8) {
            Text(segment.sourceLanguageCode.uppercased())
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12), in: Capsule())

            if segment.requiresVerification {
                Text("VERIFY")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.16), in: Capsule())
            }

            Spacer()

            Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func body(hasTranslation: Bool) -> some View {
        if hasTranslation, let translated = segment.translatedText {
            if isLandscape {
                HStack(alignment: .top, spacing: 14) {
                    Text(segment.text)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 1)
                    Text(translated)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .minimumScaleFactor(0.55)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(segment.text)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 1)
                    Text(translated)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.85))
                }
                .minimumScaleFactor(0.6)
            }
        } else {
            Text(segment.text)
                .font(.system(size: isLandscape ? 26 : 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.6)
        }
    }
}

#Preview("Portrait") {
    ContentView()
}

#Preview("Landscape", traits: .landscapeLeft) {
    ContentView()
}
