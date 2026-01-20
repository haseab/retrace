import Foundation
import Shared
import Database
import Storage

/// Coordinates audio capture → transcription → database storage pipeline
/// Owner: PROCESSING agent (Audio subdirectory)
public actor AudioProcessingManager {

    private let transcriptionService: any TranscriptionProtocol
    private var transcriptionQueries: AudioTranscriptionQueries?
    private var audioWriter: AudioSegmentWriter?
    private var isProcessing = false

    // Configuration
    private var config: AudioProcessingConfig

    // Statistics
    private var statistics = AudioProcessingStatistics(
        totalAudioSamplesProcessed: 0,
        totalTranscriptionsGenerated: 0,
        totalWordsTranscribed: 0,
        totalProcessingTime: 0,
        averageConfidence: 0,
        lastProcessedAt: nil
    )

    public init(
        transcriptionService: any TranscriptionProtocol,
        transcriptionQueries: AudioTranscriptionQueries? = nil,
        audioWriter: AudioSegmentWriter? = nil,
        config: AudioProcessingConfig = .default
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.config = config
    }

    // MARK: - Initialization

    /// Initialize the audio processing manager and transcription service
    public func initialize(
        transcriptionQueries: AudioTranscriptionQueries? = nil,
        audioWriter: AudioSegmentWriter? = nil
    ) async throws {
        if let queries = transcriptionQueries {
            self.transcriptionQueries = queries
        }
        if let writer = audioWriter {
            self.audioWriter = writer
        }
        try await transcriptionService.initialize()
    }

    // MARK: - Processing Pipeline

    /// Start processing audio stream
    public func startProcessing(audioStream: AsyncStream<CapturedAudio>) async {
        guard !isProcessing else { return }
        isProcessing = true

        for await audio in audioStream {
            await processAudio(audio)
        }

        isProcessing = false
    }

    /// Process a single audio sample
    private func processAudio(_ audio: CapturedAudio) async {
        let startTime = Date()

        do {
            // Step 1: Transcribe audio with word-level timestamps
            let transcription = try await transcriptionService.transcribeWithTimestamps(
                audio.audioData,
                wordLevel: true
            )

            guard !transcription.text.isEmpty else { return }

            // Step 2: Segment transcription into sentences
            let sentences = SentenceSegmenter.segment(
                words: transcription.words,
                fullText: transcription.text
            )

            guard !sentences.isEmpty else { return }

            // Step 3: Prepare transcription data for batch insert
            guard let queries = transcriptionQueries else {
                Log.warning("[AudioProcessingManager] Audio storage not configured, skipping save", category: .processing)
                return
            }

            // Build transcription batch data
            var transcriptionsBatch: [(
                sessionID: String?,
                text: String,
                startTime: Date,
                endTime: Date,
                source: AudioSource,
                confidence: Double?,
                words: [TranscriptionWord]
            )] = []

            for sentence in sentences {
                transcriptionsBatch.append((
                    sessionID: nil,  // TODO: Link to current app session
                    text: sentence.text,
                    startTime: audio.timestamp.addingTimeInterval(sentence.startTime),
                    endTime: audio.timestamp.addingTimeInterval(sentence.endTime),
                    source: audio.source,
                    confidence: sentence.confidence,
                    words: sentence.words
                ))
            }

            // Step 4: Batch insert all sentences in single transaction
            try await queries.insertTranscriptionsBatch(transcriptionsBatch)

            // Step 5: Update statistics
            let processingTime = Date().timeIntervalSince(startTime)
            updateStatistics(
                transcription: transcription,
                processingTime: processingTime
            )

            // Step 6: Invoke callback if configured
            if let callback = config.transcriptionCallback {
                await callback(audio, transcription)
            }

        } catch {
            Log.error("[AudioProcessingManager] Audio transcription error: \(error)", category: .processing)
            // TODO: Implement retry logic or error queue
        }
    }

    private func updateStatistics(transcription: DetailedTranscriptionResult, processingTime: TimeInterval) {
        let wordCount = transcription.words.count
        let totalConfidence = transcription.words.reduce(0.0) { $0 + ($1.confidence ?? 0) }
        let avgConfidence = wordCount > 0 ? totalConfidence / Double(wordCount) : 0

        let prevTotalSamples = Double(statistics.totalAudioSamplesProcessed)
        let prevAvgConfidence = statistics.averageConfidence

        statistics = AudioProcessingStatistics(
            totalAudioSamplesProcessed: statistics.totalAudioSamplesProcessed + 1,
            totalTranscriptionsGenerated: statistics.totalTranscriptionsGenerated + 1,
            totalWordsTranscribed: statistics.totalWordsTranscribed + wordCount,
            totalProcessingTime: statistics.totalProcessingTime + processingTime,
            averageConfidence: (prevAvgConfidence * prevTotalSamples + avgConfidence) / (prevTotalSamples + 1),
            lastProcessedAt: Date()
        )
    }

    // MARK: - Configuration

    public func updateConfig(_ config: AudioProcessingConfig) {
        self.config = config
    }

    public func getConfig() -> AudioProcessingConfig {
        return config
    }

    // MARK: - Statistics

    public func getStatistics() -> AudioProcessingStatistics {
        return statistics
    }

    public func resetStatistics() {
        statistics = AudioProcessingStatistics(
            totalAudioSamplesProcessed: 0,
            totalTranscriptionsGenerated: 0,
            totalWordsTranscribed: 0,
            totalProcessingTime: 0,
            averageConfidence: 0,
            lastProcessedAt: nil
        )
    }

    // MARK: - State

    public var isCurrentlyProcessing: Bool {
        return isProcessing
    }
}

// MARK: - Configuration

public struct AudioProcessingConfig: Sendable {
    /// Enable word-level timestamps (more expensive but more accurate)
    public let enableWordLevelTimestamps: Bool

    /// Minimum confidence threshold (0-1) to store transcription
    public let minimumConfidence: Double

    /// Maximum audio buffer size before forcing transcription (seconds)
    public let maxBufferDuration: Double

    /// Callback invoked after each transcription
    public let transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)?

    public init(
        enableWordLevelTimestamps: Bool = true,
        minimumConfidence: Double = 0.5,
        maxBufferDuration: Double = 30.0,
        transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)? = nil
    ) {
        self.enableWordLevelTimestamps = enableWordLevelTimestamps
        self.minimumConfidence = minimumConfidence
        self.maxBufferDuration = maxBufferDuration
        self.transcriptionCallback = transcriptionCallback
    }

    public static let `default` = AudioProcessingConfig()
}

// MARK: - Statistics

public struct AudioProcessingStatistics: Sendable {
    public let totalAudioSamplesProcessed: Int
    public let totalTranscriptionsGenerated: Int
    public let totalWordsTranscribed: Int
    public let totalProcessingTime: TimeInterval
    public let averageConfidence: Double
    public let lastProcessedAt: Date?

    public var averageProcessingTimePerSample: TimeInterval {
        guard totalAudioSamplesProcessed > 0 else { return 0 }
        return totalProcessingTime / Double(totalAudioSamplesProcessed)
    }

    public var averageWordsPerTranscription: Double {
        guard totalTranscriptionsGenerated > 0 else { return 0 }
        return Double(totalWordsTranscribed) / Double(totalTranscriptionsGenerated)
    }
}
