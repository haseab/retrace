import Foundation

// MARK: - Audio Capture Protocol

/// Audio capture operations with dual-pipeline architecture
/// Owner: CAPTURE agent (audio capture subdirectory)
public protocol AudioCaptureProtocol: Actor {

    // MARK: - Lifecycle

    /// Check if microphone permission is granted
    func hasMicrophonePermission() async -> Bool

    /// Request microphone permission
    func requestMicrophonePermission() async -> Bool

    /// Start capturing audio
    func startCapture(config: AudioCaptureConfig) async throws

    /// Stop capturing audio
    func stopCapture() async throws

    /// Whether capture is currently active
    var isCapturing: Bool { get }

    // MARK: - Audio Stream

    /// Stream of captured audio samples
    /// Emits samples from both microphone and system audio pipelines
    var audioStream: AsyncStream<CapturedAudio> { get }

    // MARK: - Configuration

    /// Update audio capture configuration (can be called while capturing)
    func updateConfig(_ config: AudioCaptureConfig) async throws

    /// Get current configuration
    func getConfig() async -> AudioCaptureConfig

    // MARK: - Meeting Detection & Privacy

    /// Get current meeting detection state
    func getMeetingState() async -> MeetingState

    /// Manually override system audio mute state (for testing/debugging)
    func setSystemAudioMuted(_ muted: Bool) async

    /// Get current system audio mute state
    func isSystemAudioMuted() async -> Bool

    // MARK: - Statistics

    /// Get audio capture statistics
    func getStatistics() async -> AudioCaptureStatistics
}

// MARK: - Meeting Detector Protocol

/// Detects when the user is in a video conference meeting
/// Owner: CAPTURE agent (audio capture subdirectory)
public protocol MeetingDetectorProtocol: Actor {

    /// Check if a meeting is currently active
    nonisolated func isMeetingActive() -> Bool

    /// Get the detected meeting app bundle ID, if any
    nonisolated func getActiveMeetingApp() -> String?

    /// Start monitoring for meeting activity
    func startMonitoring(bundleIDs: Set<String>)

    /// Stop monitoring
    func stopMonitoring()
}

// MARK: - Audio Format Converter Protocol

/// Converts audio to the standard format for AI transcription
/// Target: 16kHz, Mono, PCM Int16
/// Owner: CAPTURE agent (audio capture subdirectory)
public protocol AudioFormatConverterProtocol: Sendable {

    /// Convert audio buffer to target format (16kHz mono PCM Int16)
    func convertToStandardFormat(
        inputData: UnsafeRawPointer,
        inputLength: Int,
        inputSampleRate: Double,
        inputChannels: Int,
        inputFormat: AudioFormatType
    ) throws -> Data

    /// Get the target format specification
    var targetSampleRate: Int { get }
    var targetChannels: Int { get }
}

/// Audio format types
public enum AudioFormatType: Sendable {
    case float32      // AVAudioEngine native format
    case int16        // Already in target format
    case int32
}
