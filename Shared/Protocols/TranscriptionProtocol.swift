import Foundation

/// Protocol for speech-to-text transcription services
/// Owner: SHARED
public protocol TranscriptionProtocol: Actor {
    /// Initialize the transcription service
    func initialize() async throws

    /// Cleanup resources
    func cleanup()

    /// Transcribe audio data
    /// - Parameter audioData: PCM Int16 audio data at 16kHz mono
    /// - Returns: Transcription result with text and metadata
    func transcribe(_ audioData: Data) async throws -> TranscriptionResult

    /// Transcribe with word-level timestamps
    /// - Parameters:
    ///   - audioData: PCM Int16 audio data at 16kHz mono
    ///   - wordLevel: Whether to return word-level timestamps
    /// - Returns: Detailed transcription with timestamps
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool) async throws -> DetailedTranscriptionResult
}

// MARK: - Result Types

public struct TranscriptionResult: Sendable {
    public let text: String
    public let confidence: Double?
    public let language: String?
    public let duration: Double?

    public init(text: String, confidence: Double? = nil, language: String? = nil, duration: Double? = nil) {
        self.text = text
        self.confidence = confidence
        self.language = language
        self.duration = duration
    }
}

public struct DetailedTranscriptionResult: Sendable {
    public let text: String
    public let words: [TranscriptionWord]
    public let language: String?
    public let duration: Double?

    public init(text: String, words: [TranscriptionWord], language: String? = nil, duration: Double? = nil) {
        self.text = text
        self.words = words
        self.language = language
        self.duration = duration
    }
}
