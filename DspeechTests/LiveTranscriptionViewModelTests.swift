import Foundation
import Testing
@testable import Dspeech

@MainActor
struct LiveTranscriptionViewModelTests {

    @MainActor
    final class FakeEngine: LiveTranscriptionEngine {
        var status: LiveTranscriptionStatus = .idle
        var startCallCount = 0
        var stopCallCount = 0
        private var continuation: AsyncStream<LiveTranscriptionEvent>.Continuation?

        func events() -> AsyncStream<LiveTranscriptionEvent> {
            AsyncStream<LiveTranscriptionEvent> { continuation in
                self.continuation = continuation
                continuation.yield(.status(self.status))
            }
        }

        func start() async {
            startCallCount += 1
            status = .listening
            continuation?.yield(.status(.listening))
        }

        func stop() {
            stopCallCount += 1
            status = .stopped
            continuation?.yield(.status(.stopped))
        }

        func push(_ event: LiveTranscriptionEvent) {
            continuation?.yield(event)
        }
    }

    private func makeSegment(_ text: String, confidence: Double = 0.9) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            translatedText: nil,
            confidence: confidence,
            sourceLanguageCode: "en",
            source: .liveATC
        )
    }

    private func wait(for predicate: @MainActor () -> Bool, timeoutNs: UInt64 = 1_000_000_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNs) / 1_000_000_000.0)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func initialState() {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        #expect(vm.segments.isEmpty)
        #expect(vm.partialText.isEmpty)
        #expect(vm.status == .idle)
        #expect(vm.isListening == false)
    }

    @Test func startSwitchesToListening() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        await wait(for: { vm.status == .listening })
        #expect(engine.startCallCount == 1)
        #expect(vm.isListening)
    }

    @Test func partialEventUpdatesPartialText() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        engine.push(.partial("descend and"))
        await wait(for: { vm.partialText == "descend and" })
        #expect(vm.partialText == "descend and")
        #expect(vm.segments.isEmpty)
    }

    @Test func segmentEventAppendsAndClearsPartial() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        engine.push(.partial("descend and"))
        await wait(for: { vm.partialText == "descend and" })
        engine.push(.segment(makeSegment("Descend and maintain three thousand.")))
        await wait(for: { vm.segments.count == 1 })
        #expect(vm.segments.first?.text == "Descend and maintain three thousand.")
        #expect(vm.segments.first?.source == .liveATC)
        #expect(vm.partialText.isEmpty)
    }

    @Test func failedStatusExposesErrorMessage() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        engine.push(.status(.failed("microphone-permission-denied")))
        await wait(for: { vm.lastErrorMessage == "microphone-permission-denied" })
        #expect(vm.lastErrorMessage == "microphone-permission-denied")
        #expect(vm.isListening == false)
    }

    @Test func stopInvokesEngineAndClearsListening() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        await wait(for: { vm.status == .listening })
        vm.stop()
        await wait(for: { vm.status == .stopped })
        #expect(engine.stopCallCount == 1)
        #expect(vm.isListening == false)
        #expect(vm.status == .stopped)
    }

    @Test func resetClearsSegmentsAndPartial() async {
        let engine = FakeEngine()
        let vm = LiveTranscriptionViewModel(engine: engine)
        await vm.start()
        engine.push(.segment(makeSegment("one")))
        engine.push(.segment(makeSegment("two")))
        engine.push(.partial("partial three"))
        await wait(for: { vm.segments.count == 2 && vm.partialText == "partial three" })
        vm.reset()
        #expect(vm.segments.isEmpty)
        #expect(vm.partialText.isEmpty)
    }
}
