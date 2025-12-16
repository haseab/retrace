import Foundation
import AVFoundation
import CoreAudio
import Shared

/// Microphone audio capture (Pipeline A)
/// Uses AVAudioEngine with Voice Processing enabled for hardware-accelerated
/// echo cancellation and background noise removal (Voice Isolation)
public actor MicrophoneAudioCapture {

    private let audioEngine = AVAudioEngine()
    private let formatConverter: AudioFormatConverter
    private var isRunning = false

    // Audio stream
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?

    // Configuration
    private var config: AudioCaptureConfig

    public init(config: AudioCaptureConfig) {
        self.config = config
        self.formatConverter = AudioFormatConverter()
    }

    // MARK: - Permission

    /// Check microphone permission
    public func hasPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }

    /// Request microphone permission
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lifecycle

    /// Start capturing microphone audio
    public func startCapture() throws {
        guard !isRunning else { return }

        // Create audio stream
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self._audioStream = stream
        self.audioContinuation = continuation

        // Configure audio engine
        try configureAudioEngine()

        // Start the engine
        try audioEngine.start()
        isRunning = true
    }

    /// Stop capturing
    public func stopCapture() {
        guard isRunning else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false

        audioContinuation?.finish()
        audioContinuation = nil
    }

    /// Get audio stream
    public var audioStream: AsyncStream<CapturedAudio> {
        get async {
            if let stream = _audioStream {
                return stream
            }

            let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
            self._audioStream = stream
            self.audioContinuation = continuation
            return stream
        }
    }

    /// Update configuration
    public func updateConfig(_ newConfig: AudioCaptureConfig) async throws {
        let wasRunning = isRunning

        if wasRunning {
            stopCapture()
        }

        self.config = newConfig

        if wasRunning {
            try startCapture()
        }
    }

    // MARK: - Private Configuration

    private func configureAudioEngine() throws {
        let inputNode = audioEngine.inputNode

        // CRITICAL: Enable Voice Processing (Voice Isolation)
        // This provides hardware-accelerated echo cancellation and noise removal
        // This is NON-NEGOTIABLE per privacy policy requirements
        if config.voiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw AudioCaptureError.invalidConfiguration(
                    "Voice Processing is required but could not be enabled: \(error.localizedDescription)"
                )
            }
        }

        // Get input format
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap to capture audio
        let bufferSize = AVAudioFrameCount(config.bufferDurationSeconds * inputFormat.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            Task {
                await self?.processAudioBuffer(buffer, timestamp: time)
            }
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, timestamp: AVAudioTime) async {
        guard let audioContinuation = self.audioContinuation else { return }

        do {
            // Convert to standard format (16kHz mono PCM Int16)
            let convertedData = try convertBuffer(buffer)

            let capturedAudio = CapturedAudio(
                timestamp: Date(),
                audioData: convertedData,
                duration: Double(buffer.frameLength) / buffer.format.sampleRate,
                source: .microphone,
                sampleRate: formatConverter.targetSampleRate,
                channels: formatConverter.targetChannels
            )

            audioContinuation.yield(capturedAudio)

        } catch {
            print("Error converting microphone audio: \(error)")
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let inputFormat = buffer.format

        // If we have float32 data (AVAudioEngine's native format)
        guard let floatChannelData = buffer.floatChannelData else {
            throw AudioCaptureError.formatConversionFailed
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(inputFormat.channelCount)

        // Interleave channels if needed
        var interleavedSamples = [Float]()
        interleavedSamples.reserveCapacity(frameLength * channelCount)

        if channelCount == 1 {
            // Mono - direct copy
            let channelData = UnsafeBufferPointer(start: floatChannelData[0], count: frameLength)
            interleavedSamples.append(contentsOf: channelData)
        } else {
            // Multi-channel - interleave
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    interleavedSamples.append(floatChannelData[channel][frame])
                }
            }
        }

        // Convert to standard format
        return try interleavedSamples.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try formatConverter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: interleavedSamples.count * MemoryLayout<Float>.size,
                inputSampleRate: inputFormat.sampleRate,
                inputChannels: channelCount,
                inputFormat: .float32
            )
        }
    }
}

// MARK: - Voice Processing Validation

extension MicrophoneAudioCapture {

    /// Verify that Voice Processing is actually enabled
    /// Use this for testing/debugging
    public func isVoiceProcessingEnabled() -> Bool {
        return audioEngine.inputNode.isVoiceProcessingEnabled
    }

    /// Get current audio format information
    public func getInputFormat() -> (sampleRate: Double, channels: Int) {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        return (format.sampleRate, Int(format.channelCount))
    }
}
