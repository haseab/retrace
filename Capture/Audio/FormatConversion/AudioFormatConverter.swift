import Foundation
import AVFoundation
import Accelerate
import Shared

/// Converts audio to standard format for AI transcription
/// Target: 16kHz, Mono, PCM Int16 (required by OpenAI Whisper and CoreML WhisperKit)
public struct AudioFormatConverter: AudioFormatConverterProtocol {

    public let targetSampleRate: Int = 16000
    public let targetChannels: Int = 1

    public init() {}

    /// Convert audio to 16kHz mono PCM Int16
    public func convertToStandardFormat(
        inputData: UnsafeRawPointer,
        inputLength: Int,
        inputSampleRate: Double,
        inputChannels: Int,
        inputFormat: AudioFormatType
    ) throws -> Data {

        // Step 1: Convert to Float32 if not already
        let float32Samples: [Float]
        let sampleCount = inputLength / inputChannels / Self.bytesPerSample(format: inputFormat)

        switch inputFormat {
        case .float32:
            float32Samples = Array(UnsafeBufferPointer(
                start: inputData.assumingMemoryBound(to: Float.self),
                count: sampleCount * inputChannels
            ))

        case .int16:
            let int16Samples = Array(UnsafeBufferPointer(
                start: inputData.assumingMemoryBound(to: Int16.self),
                count: sampleCount * inputChannels
            ))
            // Use 32767 for symmetric conversion with Float→Int16
            float32Samples = int16Samples.map { Float($0) / 32767.0 }

        case .int32:
            let int32Samples = Array(UnsafeBufferPointer(
                start: inputData.assumingMemoryBound(to: Int32.self),
                count: sampleCount * inputChannels
            ))
            float32Samples = int32Samples.map { Float($0) / 2147483648.0 }
        }

        // Step 2: Convert to mono if needed
        let monoSamples: [Float]
        if inputChannels == 1 {
            monoSamples = float32Samples
        } else {
            monoSamples = try convertToMono(samples: float32Samples, channels: inputChannels)
        }

        // Step 3: Resample to 16kHz if needed
        let resampledSamples: [Float]
        if abs(inputSampleRate - 16000.0) < 0.1 {
            resampledSamples = monoSamples
        } else {
            resampledSamples = try resample(
                samples: monoSamples,
                fromRate: inputSampleRate,
                toRate: 16000.0
            )
        }

        // Step 4: Convert to Int16 PCM
        // Use 32767 for symmetric conversion (standard audio practice)
        let int16Samples = resampledSamples.map { sample -> Int16 in
            let clampedSample = max(-1.0, min(1.0, sample))
            return Int16(clampedSample * 32767.0)
        }

        // Step 5: Convert to Data
        return Data(bytes: int16Samples, count: int16Samples.count * 2)
    }

    // MARK: - Private Helpers

    private static func bytesPerSample(format: AudioFormatType) -> Int {
        switch format {
        case .float32: return 4
        case .int16: return 2
        case .int32: return 4
        }
    }

    /// Convert multi-channel audio to mono by averaging channels
    private func convertToMono(samples: [Float], channels: Int) throws -> [Float] {
        guard channels > 1 else { return samples }

        let frameCount = samples.count / channels
        var monoSamples = [Float](repeating: 0.0, count: frameCount)

        for frame in 0..<frameCount {
            var sum: Float = 0.0
            for channel in 0..<channels {
                sum += samples[frame * channels + channel]
            }
            monoSamples[frame] = sum / Float(channels)
        }

        return monoSamples
    }

    /// Resample audio using linear interpolation
    /// For production, consider using AVAudioConverter or vDSP for higher quality
    private func resample(samples: [Float], fromRate: Double, toRate: Double) throws -> [Float] {
        let ratio = fromRate / toRate
        let outputLength = Int(Double(samples.count) / ratio)
        var resampled = [Float](repeating: 0.0, count: outputLength)

        for i in 0..<outputLength {
            let sourceIndex = Double(i) * ratio

            let index0 = Int(floor(sourceIndex))
            let index1 = min(index0 + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(index0))

            // Linear interpolation
            resampled[i] = samples[index0] * (1.0 - fraction) + samples[index1] * fraction
        }

        return resampled
    }
}

// MARK: - AVAudioConverter Extension

extension AudioFormatConverter {

    /// High-quality resampling using AVAudioConverter
    /// This is preferred over linear interpolation for production use
    public func resampleWithAVAudioConverter(
        buffer: AVAudioPCMBuffer,
        targetSampleRate: Double
    ) throws -> AVAudioPCMBuffer {

        let inputFormat = buffer.format
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatConversionFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.formatConversionFailed
        }

        let inputFrameCount = buffer.frameLength
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioCaptureError.bufferAllocationFailed
        }

        var inputConsumed = false

        try converter.convert(to: outputBuffer, error: nil) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }

            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        return outputBuffer
    }
}

// MARK: - Audio Capture Errors

public enum AudioCaptureError: Error, Sendable {
    case permissionDenied
    case audioEngineStartFailed(String)
    case captureSessionFailed(String)
    case formatConversionFailed
    case bufferAllocationFailed
    case invalidConfiguration(String)
    case systemAudioNotAvailable
    case meetingDetectionFailed
}
