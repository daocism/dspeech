import Foundation

@MainActor
final class SerialBufferRouter<Buffer> {
    private struct Item {
        let buffer: Buffer
        let samples: [Float]
        let sampleRate: Double
    }

    private let classify: @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision
    private let append: (Buffer) -> Void

    private var queue: [Item] = []
    private var isDraining = false
    private var finished = false

    init(
        classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
        append: @escaping (Buffer) -> Void
    ) {
        self.classify = classify
        self.append = append
    }

    func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double) {
        guard !finished else { return }
        queue.append(Item(buffer: buffer, samples: samples, sampleRate: sampleRate))
        drainIfNeeded()
    }

    func finish() {
        finished = true
        queue.removeAll()
    }

    private func drainIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in await self.drain() }
    }

    private func drain() async {
        while !finished, !queue.isEmpty {
            let item = queue.removeFirst()
            let decision: PreTranscriptionRoutingDecision
            do {
                decision = try await classify(item.samples, item.sampleRate)
            } catch {
                // why: fail open — a thrown classifier must append (transcribe), never
                // silently drop ATC audio, and must not disturb FIFO order.
                decision = .transcribe(reason: .classifierUnavailable)
            }
            // why: stop()/cleanup may have called finish() while classifying; a
            // post-finish buffer must never reach the ended recognition request.
            guard !finished else { break }
            switch decision {
            case .transcribe:
                append(item.buffer)
            case .discard:
                continue
            }
        }
        isDraining = false
    }
}
