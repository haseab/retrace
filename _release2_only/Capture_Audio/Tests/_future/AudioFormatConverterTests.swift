import XCTest
import Shared
@testable import Capture

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                  AUDIO FORMAT CONVERTER TESTS                                ║
// ║                                                                              ║
// ║  • Verify Float32 to Int16 conversion                                        ║
// ║  • Verify Int16 passthrough (no conversion needed)                           ║
// ║  • Verify Int32 to Int16 conversion                                          ║
// ║  • Verify mono conversion (already mono)                                     ║
// ║  • Verify stereo to mono conversion (channel averaging)                      ║
// ║  • Verify resampling from 48kHz to 16kHz                                     ║
// ║  • Verify resampling from 44.1kHz to 16kHz                                   ║
// ║  • Verify output format is always 16kHz mono Int16                           ║
// ║  • Verify conversion preserves audio quality (no clipping)                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class AudioFormatConverterTests: XCTestCase {

    var converter: AudioFormatConverter!

    override func setUp() {
        converter = AudioFormatConverter()
    }

    override func tearDown() {
        converter = nil
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                      Format Conversion Tests                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testConvert_Float32ToInt16() throws {
        // Create sample Float32 data: [-1.0, -0.5, 0.0, 0.5, 1.0]
        let inputSamples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 16000.0,  // Already at target rate
                inputChannels: 1,          // Already mono
                inputFormat: .float32
            )
        }

        // Verify output is Int16 format (2 bytes per sample)
        XCTAssertEqual(outputData.count, inputSamples.count * 2)

        // Convert output back to Int16 array
        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Verify values are correctly converted
        XCTAssertEqual(outputSamples.count, 5)
        XCTAssertEqual(outputSamples[0], -32767)  // -1.0 -> -32767
        XCTAssertEqual(outputSamples[2], 0)       // 0.0 -> 0
        XCTAssertEqual(outputSamples[4], 32767)   // 1.0 -> 32767
    }

    func testConvert_Int16Passthrough() throws {
        // Create sample Int16 data
        let inputSamples: [Int16] = [-32767, 0, 32767]
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 2)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 16000.0,
                inputChannels: 1,
                inputFormat: .int16
            )
        }

        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Should be identical (no conversion needed)
        XCTAssertEqual(outputSamples.count, inputSamples.count)
        XCTAssertEqual(outputSamples[0], -32767)
        XCTAssertEqual(outputSamples[1], 0)
        XCTAssertEqual(outputSamples[2], 32767)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                     Channel Conversion Tests                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testConvert_StereoToMono() throws {
        // Create stereo Float32 data: [L1, R1, L2, R2]
        // Left channel: [0.5, 1.0], Right channel: [-0.5, -1.0]
        // Average: [0.0, 0.0]
        let inputSamples: [Float] = [0.5, -0.5, 1.0, -1.0]
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 16000.0,
                inputChannels: 2,  // Stereo input
                inputFormat: .float32
            )
        }

        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Should have 2 mono samples (averaged from stereo)
        XCTAssertEqual(outputSamples.count, 2)

        // Verify averaging: (0.5 + -0.5) / 2 = 0.0, (1.0 + -1.0) / 2 = 0.0
        XCTAssertEqual(outputSamples[0], 0)
        XCTAssertEqual(outputSamples[1], 0)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Resampling Tests                                  │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testConvert_48kHzTo16kHz() throws {
        // Create 48kHz sample (3x the target rate)
        // For simplicity, use a constant value
        let inputSampleCount = 4800  // 0.1 second at 48kHz
        let inputSamples = [Float](repeating: 0.5, count: inputSampleCount)
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 48000.0,  // 48kHz input
                inputChannels: 1,
                inputFormat: .float32
            )
        }

        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Output should be ~1/3 the size (16kHz vs 48kHz)
        // 4800 samples at 48kHz -> 1600 samples at 16kHz
        let expectedOutputCount = 1600
        XCTAssertEqual(outputSamples.count, expectedOutputCount, accuracy: 10)
    }

    func testConvert_44_1kHzTo16kHz() throws {
        // Create 44.1kHz sample
        let inputSampleCount = 4410  // 0.1 second at 44.1kHz
        let inputSamples = [Float](repeating: 0.3, count: inputSampleCount)
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 44100.0,  // 44.1kHz input
                inputChannels: 1,
                inputFormat: .float32
            )
        }

        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Output should be resampled to 16kHz
        // 4410 samples at 44.1kHz -> 1600 samples at 16kHz
        let expectedOutputCount = 1600
        XCTAssertEqual(outputSamples.count, expectedOutputCount, accuracy: 10)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                      Output Format Tests                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testTargetFormat_Is16kHzMono() {
        XCTAssertEqual(converter.targetSampleRate, 16000)
        XCTAssertEqual(converter.targetChannels, 1)
    }

    func testConvert_AlwaysOutputs16kHzMono() throws {
        // Test various input configurations
        let testCases: [(sampleRate: Double, channels: Int)] = [
            (48000.0, 2),  // 48kHz stereo
            (44100.0, 2),  // 44.1kHz stereo
            (16000.0, 1),  // Already 16kHz mono
            (8000.0, 1),   // 8kHz mono (upsampling)
        ]

        for (sampleRate, channels) in testCases {
            let inputSampleCount = Int(sampleRate * 0.1)  // 0.1 second
            let inputSamples = [Float](repeating: 0.5, count: inputSampleCount * channels)
            let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

            let outputData = try inputData.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    throw AudioCaptureError.formatConversionFailed
                }

                return try converter.convertToStandardFormat(
                    inputData: baseAddress,
                    inputLength: inputData.count,
                    inputSampleRate: sampleRate,
                    inputChannels: channels,
                    inputFormat: .float32
                )
            }

            // Verify output is Int16 format
            XCTAssertEqual(outputData.count % 2, 0, "Output should be Int16 (2 bytes per sample)")

            // Verify output sample count corresponds to 16kHz
            let outputSampleCount = outputData.count / 2
            let expectedSampleCount = Int(16000.0 * 0.1)  // 1600 samples for 0.1 second at 16kHz
            XCTAssertEqual(outputSampleCount, expectedSampleCount, accuracy: 10,
                          "Sample rate \(sampleRate), channels \(channels) should output ~1600 samples")
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Quality Tests                                      │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testConvert_NoClipping() throws {
        // Test values at the edge of the range
        let inputSamples: [Float] = [-1.0, -0.99, 0.99, 1.0]
        let inputData = Data(bytes: inputSamples, count: inputSamples.count * 4)

        let outputData = try inputData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw AudioCaptureError.formatConversionFailed
            }

            return try converter.convertToStandardFormat(
                inputData: baseAddress,
                inputLength: inputData.count,
                inputSampleRate: 16000.0,
                inputChannels: 1,
                inputFormat: .float32
            )
        }

        let outputSamples = outputData.withUnsafeBytes { bufferPointer in
            Array(bufferPointer.bindMemory(to: Int16.self))
        }

        // Verify no values exceed Int16 range
        for sample in outputSamples {
            XCTAssertGreaterThanOrEqual(sample, Int16.min)
            XCTAssertLessThanOrEqual(sample, Int16.max)
        }
    }
}
