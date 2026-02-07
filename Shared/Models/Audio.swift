import Foundation

// Import AudioSource from TextRegion
// Note: AudioSource is defined in TextRegion.swift

// MARK: - Audio Models

/// Captured audio data
public struct CapturedAudio: Sendable {
    /// Unique identifier for this audio sample
    public let id: UUID

    /// Timestamp when audio was captured
    public let timestamp: Date

    /// Audio data in PCM Int16 format, 16kHz mono
    public let audioData: Data

    /// Duration of the audio sample in seconds
    public let duration: TimeInterval

    /// Audio source type
    public let source: AudioSource

    /// Sample rate (should always be 16000 for AI transcription)
    public let sampleRate: Int

    /// Number of channels (should always be 1 for mono)
    public let channels: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        audioData: Data,
        duration: TimeInterval,
        source: AudioSource,
        sampleRate: Int = 16000,
        channels: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.audioData = audioData
        self.duration = duration
        self.source = source
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Audio capture statistics
public struct AudioCaptureStatistics: Sendable {
    public let microphoneSamplesRecorded: Int
    public let systemAudioSamplesRecorded: Int
    public let microphoneDurationSeconds: TimeInterval
    public let systemAudioDurationSeconds: TimeInterval
    public let captureStartTime: Date?
    public let lastSampleTime: Date?
    public let meetingDetectedCount: Int
    public let autoMuteCount: Int

    public init(
        microphoneSamplesRecorded: Int,
        systemAudioSamplesRecorded: Int,
        microphoneDurationSeconds: TimeInterval,
        systemAudioDurationSeconds: TimeInterval,
        captureStartTime: Date?,
        lastSampleTime: Date?,
        meetingDetectedCount: Int,
        autoMuteCount: Int
    ) {
        self.microphoneSamplesRecorded = microphoneSamplesRecorded
        self.systemAudioSamplesRecorded = systemAudioSamplesRecorded
        self.microphoneDurationSeconds = microphoneDurationSeconds
        self.systemAudioDurationSeconds = systemAudioDurationSeconds
        self.captureStartTime = captureStartTime
        self.lastSampleTime = lastSampleTime
        self.meetingDetectedCount = meetingDetectedCount
        self.autoMuteCount = autoMuteCount
    }
}

/// Meeting detection state
public struct MeetingState: Sendable {
    public let isInMeeting: Bool
    public let detectedApp: String?
    public let detectedAt: Date?

    public init(isInMeeting: Bool, detectedApp: String? = nil, detectedAt: Date? = nil) {
        self.isInMeeting = isInMeeting
        self.detectedApp = detectedApp
        self.detectedAt = detectedAt
    }

    public static let notInMeeting = MeetingState(isInMeeting: false)
}

/// Transcription word timing information
public struct TranscriptionWord: Sendable {
    public let word: String
    public let start: Double  // Seconds from start of audio
    public let end: Double
    public let confidence: Double?

    public init(word: String, start: Double, end: Double, confidence: Double? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Audio sentence with transcription and file reference
/// Used for timeline playback and search results
public struct AudioSentence: Sendable, Identifiable {
    public let id: String
    public let sessionID: String?
    public let text: String
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let source: AudioSource
    public let confidence: Double
    public let wordCount: Int
    public let filePath: String
    public let fileSize: Int64
    public let createdAt: Date

    public init(
        id: String,
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        duration: TimeInterval,
        source: AudioSource,
        confidence: Double,
        wordCount: Int,
        filePath: String,
        fileSize: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.source = source
        self.confidence = confidence
        self.wordCount = wordCount
        self.filePath = filePath
        self.fileSize = fileSize
        self.createdAt = createdAt
    }
}
