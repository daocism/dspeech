import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptDemoViewModel.demo

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.03, green: 0.06, blue: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    header

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentRow(segment: segment)
                            }
                        }
                    }

                    footer
                }
                .padding(28)
            }
            .navigationTitle("Dispeech")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dispeech")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityIdentifier("app-title")

            Text("Receive-only ATC transcription prototype")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Demo input", systemImage: "waveform")
            Label("Local-first", systemImage: "lock.shield")
            Label("Verify low confidence", systemImage: "exclamationmark.triangle")
        }
        .font(.headline)
        .foregroundStyle(.cyan.opacity(0.88))
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(segment.sourceLanguageCode.uppercased())
                    .font(.caption.monospaced().weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())

                if segment.requiresVerification {
                    Text("VERIFY ORIGINAL")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow.opacity(0.16), in: Capsule())
                }

                Spacer()

                Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }

            Text(segment.text)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.65)
        }
        .padding(18)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }
}

#Preview("Landscape cockpit view", traits: .landscapeLeft) {
    ContentView()
}
