import Foundation

struct TranscriptSegment: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case liveATC
        case replay
        case demo
    }

    let id: UUID
    let startedAt: Date
    let text: String
    let translatedText: String?
    let confidence: Double
    let sourceLanguageCode: String
    let source: Source

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        text: String,
        translatedText: String? = nil,
        confidence: Double,
        sourceLanguageCode: String,
        source: Source
    ) {
        self.id = id
        self.startedAt = startedAt
        self.text = text
        self.translatedText = translatedText
        self.confidence = confidence
        self.sourceLanguageCode = sourceLanguageCode
        self.source = source
    }

    var requiresVerification: Bool {
        confidence < 0.82
    }
}
