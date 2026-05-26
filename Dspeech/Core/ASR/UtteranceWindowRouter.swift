import Foundation

@MainActor
final class UtteranceWindowRouter<Buffer> {
    private struct Pending {
        let buffer: Buffer
        let samples: [Float]
        let sampleRate: Double
    }

    private let minimumChunkSamples: Int
    private let append: (Buffer) -> Void
    private let inner: SerialBufferRouter<[Buffer]>

    private var pending: [Pending] = []
    private var pendingSampleCount = 0
    private var finished = false

    init(
        minimumChunkSamples: Int,
        classify: @escaping @Sendable ([Float], Double) async throws -> PreTranscriptionRoutingDecision,
        append: @escaping (Buffer) -> Void
    ) {
        self.minimumChunkSamples = max(minimumChunkSamples, 1)
        self.append = append
        self.inner = SerialBufferRouter<[Buffer]>(
            classify: classify,
            // why: one classification decides the whole window — every buffer in
            // the chunk is appended together, in capture order, or none is.
            append: { chunk in for buffer in chunk { append(buffer) } }
        )
    }

    func submit(_ buffer: Buffer, samples: [Float], sampleRate: Double) {
        guard !finished else { return }
        pending.append(Pending(buffer: buffer, samples: samples, sampleRate: sampleRate))
        pendingSampleCount += samples.count
        // why: a window is only eligible for a confident discard once it carries a
        // coherent amount of audio; below threshold it is never classified, so an
        // isolated pilot-leaning fragment can't silently remove ATC audio.
        if pendingSampleCount >= minimumChunkSamples {
            cutChunk()
        }
    }

    func finish() {
        finished = true
        // why: the pending tail never reached a decision window, so it is
        // uncertain — flush it to ASR (fail open) before the request ends rather
        // than discard it. This runs synchronously, ahead of endAudio(); the inner
        // router then blocks any in-flight chunk from appending post-finish.
        let tail = pending.map(\.buffer)
        pending.removeAll()
        pendingSampleCount = 0
        for buffer in tail { append(buffer) }
        inner.finish()
    }

    private func cutChunk() {
        let buffers = pending.map(\.buffer)
        let samples = pending.flatMap(\.samples)
        let sampleRate = pending.last?.sampleRate ?? 0
        pending.removeAll()
        pendingSampleCount = 0
        inner.submit(buffers, samples: samples, sampleRate: sampleRate)
    }
}
