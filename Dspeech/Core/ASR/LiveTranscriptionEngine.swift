import Foundation

enum LiveTranscriptionStatus: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case listening
    case stopped
    case failed(String)
}

enum LiveTranscriptionEvent: Sendable {
    case partial(String)
    case segment(TranscriptSegment)
    case status(LiveTranscriptionStatus)
}

@MainActor
protocol LiveTranscriptionEngine: AnyObject {
    var status: LiveTranscriptionStatus { get }
    func events() -> AsyncStream<LiveTranscriptionEvent>
    func start() async
    func stop()
}
