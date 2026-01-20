import Foundation
import Shared

/// Mock transcription service for testing
/// Returns empty/stub results without loading any models
/// Owner: PROCESSING agent
public actor MockTranscriptionService: TranscriptionProtocol {

    private var isInitialized = false

    public init() {}

    public func initialize() async throws {
        // No heavy model loading - just mark as initialized
        isInitialized = true
    }

    public func cleanup() {
        isInitialized = false
    }

    public func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }

        // Return empty transcription
        return TranscriptionResult(
            text: "",
            confidence: 1.0,
            language: "en",
            duration: 0.0
        )
    }

    public func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool) async throws -> DetailedTranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }

        // Return empty detailed transcription
        return DetailedTranscriptionResult(
            text: "",
            words: [],
            language: "en",
            duration: 0.0
        )
    }
}
