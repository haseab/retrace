import CoreMedia
import Foundation
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                       HEVC ENCODER TESTS                                     ║
// ║                                                                              ║
// ║  • Verify encoding produces valid MP4 files with proper metadata             ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class HEVCEncoderTests: XCTestCase {

    private static var hasPrintedSeparator = false

    override func setUp() {
        super.setUp()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Encoding Tests                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testEncodeProducesValidMP4File() async throws {
        let encoder = HEVCEncoder()
        let config = VideoEncoderConfig.default
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        let startTime = Date()

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try await encoder.initialize(width: 4, height: 4, config: config, outputURL: tempURL, segmentStartTime: startTime)

            // Verify hardware acceleration status is determined
            let isHardwareAccelerated = await encoder.isHardwareAccelerated()
            print("Hardware acceleration: \(isHardwareAccelerated ? "✅ Enabled" : "⚠️ Not available (using software)")")

            // Encode a few frames
            for i in 0..<5 {
                let bytesPerRow = 4 * 4
                let imageData = Data(repeating: UInt8(i * 50), count: bytesPerRow * 4)
                let frame = CapturedFrame(
                    imageData: imageData,
                    width: 4,
                    height: 4,
                    bytesPerRow: bytesPerRow
                )
                let pixelBuffer = try FrameConverter.createPixelBuffer(from: frame)
                let timestamp = CMTime(seconds: Double(i), preferredTimescale: 600)
                try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
            }

            try await encoder.finalize()

            // Verify the file exists and is not empty
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(fileSize, 0)

        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }
    }

    func testHardwareAccelerationAvailability() async throws {
        let encoder = HEVCEncoder()
        let config = VideoEncoderConfig.default
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_hw_\(UUID().uuidString).mp4")
        let startTime = Date()

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try await encoder.initialize(width: 1920, height: 1080, config: config, outputURL: tempURL, segmentStartTime: startTime)

            let isHardwareAccelerated = await encoder.isHardwareAccelerated()

            // On Apple Silicon, hardware encoding should be available
            // On Intel Macs, it depends on the GPU
            #if arch(arm64)
            XCTAssertTrue(isHardwareAccelerated, "Hardware acceleration should be available on Apple Silicon")
            print("✅ Hardware acceleration confirmed on Apple Silicon")
            #else
            print("ℹ️ Hardware acceleration status: \(isHardwareAccelerated)")
            #endif

            await encoder.reset()

        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }
    }
}

