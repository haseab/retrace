import XCTest
import Shared
@testable import Capture

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                        DEDUPLICATION TESTS                                   ║
// ║                                                                              ║
// ║  • Verify hash computation produces consistent hashes for identical images   ║
// ║  • Verify hash computation produces different hashes for different images    ║
// ║  • Verify similarity computation returns 1.0 for identical frames            ║
// ║  • Verify similarity computation returns low values for different frames     ║
// ║  • Verify similarity computation returns high values for similar frames      ║
// ║  • Verify similarity returns 0.0 for frames with different dimensions        ║
// ║  • Verify shouldKeepFrame always keeps first frame (no reference)            ║
// ║  • Verify shouldKeepFrame filters identical frames with high threshold       ║
// ║  • Verify shouldKeepFrame keeps different frames                             ║
// ║  • Verify shouldKeepFrame keeps frames when dimensions change                ║
// ║  • Verify hash computation performance on full HD images                     ║
// ║  • Verify similarity computation performance on full HD images               ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class DeduplicationTests: XCTestCase {

    var deduplicator: FrameDeduplicator!
    private static var hasPrintedSeparator = false

    override func setUp() {
        super.setUp()
        deduplicator = FrameDeduplicator()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() {
        deduplicator = nil
        super.tearDown()
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                      Hash Computation Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testComputeHash_SameImage_ProducesSameHash() {
        // Create identical frames
        let imageData = createTestImageData(width: 100, height: 100, color: 128)
        let frame1 = createTestFrame(imageData: imageData, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData, width: 100, height: 100)

        let hash1 = deduplicator.computeHash(for: frame1)
        let hash2 = deduplicator.computeHash(for: frame2)

        XCTAssertEqual(hash1, hash2, "Identical images should produce identical hashes")
    }

    func testComputeHash_DifferentImages_ProduceDifferentHashes() {
        // Create different frames
        let imageData1 = createTestImageData(width: 100, height: 100, color: 50)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 200)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let hash1 = deduplicator.computeHash(for: frame1)
        let hash2 = deduplicator.computeHash(for: frame2)

        XCTAssertNotEqual(hash1, hash2, "Different images should produce different hashes")
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                          Similarity Tests                                │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testComputeSimilarity_IdenticalFrames_ReturnsOne() {
        let imageData = createTestImageData(width: 100, height: 100, color: 128)
        let frame1 = createTestFrame(imageData: imageData, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        XCTAssertEqual(similarity, 1.0, accuracy: 0.01, "Identical frames should have similarity of 1.0")
    }

    func testComputeSimilarity_CompletelyDifferent_ReturnsLow() {
        // Create images with very different stripe patterns (narrow vs wide)
        let imageData1 = createTestImageData(width: 100, height: 100, color: 10)  // narrow stripes
        let imageData2 = createTestImageData(width: 100, height: 100, color: 200) // wide stripes

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        // dHash similarity for different patterns should be relatively low
        XCTAssertLessThan(similarity, 0.8, "Different stripe patterns should have lower similarity")
    }

    func testComputeSimilarity_SlightlyDifferent_ReturnsHigh() {
        // Create two images with identical pattern structure (same stripe width)
        let imageData1 = createTestImageData(width: 100, height: 100, color: 120)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 121) // identical stripe width (both 12)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        // dHash focuses on structure, not exact pixel values, so identical patterns should match well
        XCTAssertGreaterThan(similarity, 0.7, "Identical stripe patterns should have high similarity")
    }

    func testComputeSimilarity_DifferentSizes_ReturnsZero() {
        let imageData1 = createTestImageData(width: 100, height: 100, color: 128)
        let imageData2 = createTestImageData(width: 200, height: 200, color: 128)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 200, height: 200)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        XCTAssertEqual(similarity, 0.0, "Frames with different sizes should have zero similarity")
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Should Keep Frame Tests                            │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testShouldKeepFrame_NoReference_ReturnsTrue() {
        let imageData = createTestImageData(width: 100, height: 100, color: 128)
        let frame = createTestFrame(imageData: imageData, width: 100, height: 100)

        let shouldKeep = deduplicator.shouldKeepFrame(frame, comparedTo: nil, threshold: 0.98)

        XCTAssertTrue(shouldKeep, "Should always keep frame when there's no reference")
    }

    func testShouldKeepFrame_IdenticalFrames_HighThreshold_ReturnsFalse() {
        let imageData = createTestImageData(width: 100, height: 100, color: 128)
        let frame1 = createTestFrame(imageData: imageData, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData, width: 100, height: 100)

        // High threshold (0.98) = strict filtering
        // Identical frames have similarity 1.0, which is NOT > 0.98, so they get filtered
        let shouldKeep = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.98)

        XCTAssertFalse(shouldKeep, "Should filter identical frames with high threshold")
    }

    func testShouldKeepFrame_DifferentFrames_LowThreshold_ReturnsTrue() {
        let imageData1 = createTestImageData(width: 100, height: 100, color: 50)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 200)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        // Low threshold (0.02) = lenient filtering, max allowed similarity = 0.98
        // Different frames have similarity < 0.8, which is well below 0.98, so they're kept
        let shouldKeep = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.02)

        XCTAssertTrue(shouldKeep, "Should keep very different frames with lenient threshold")
    }

    func testShouldKeepFrame_DifferentSizes_ReturnsTrue() {
        let imageData1 = createTestImageData(width: 100, height: 100, color: 128)
        let imageData2 = createTestImageData(width: 200, height: 200, color: 128)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 200, height: 200)

        let shouldKeep = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.98)

        XCTAssertTrue(shouldKeep, "Should keep frame when dimensions change")
    }

    func testThresholdSemantics_HigherIsStricter() {
        // Create two frames with different stripe patterns
        // color 80 → stripe width 8
        // color 150 → stripe width 15 (significantly different pattern)
        let imageData1 = createTestImageData(width: 100, height: 100, color: 80)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 150)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        // These should be somewhat similar (same type of pattern) but not identical
        XCTAssertGreaterThanOrEqual(similarity, 0.4, "Test frames should have some similarity (>=0.4)")
        XCTAssertLessThan(similarity, 1.0, "Test frames should not be identical (<1.0)")

        // Low threshold (0.02) = lenient = max allowed similarity 0.98
        // Should KEEP frames unless they're nearly identical (similarity > 0.98)
        let shouldKeepLowThreshold = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.02)
        XCTAssertTrue(shouldKeepLowThreshold, "Low threshold should keep similar frames")

        // High threshold (0.98) = very strict = max allowed similarity 0.02
        // Should FILTER almost everything except very different frames
        let shouldKeepHighThreshold = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.98)
        XCTAssertFalse(shouldKeepHighThreshold, "High threshold should filter similar frames")

        // Verify: higher threshold filters more frames (is stricter)
        XCTAssertTrue(shouldKeepLowThreshold, "Low threshold keeps frames")
        XCTAssertFalse(shouldKeepHighThreshold, "High threshold filters frames")
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Performance Tests                                │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testHashPerformance() {
        let imageData = createTestImageData(width: 1920, height: 1080, color: 128)
        let frame = createTestFrame(imageData: imageData, width: 1920, height: 1080)

        measure {
            _ = deduplicator.computeHash(for: frame)
        }
    }

    func testSimilarityPerformance() {
        let imageData1 = createTestImageData(width: 1920, height: 1080, color: 128)
        let imageData2 = createTestImageData(width: 1920, height: 1080, color: 130)

        let frame1 = createTestFrame(imageData: imageData1, width: 1920, height: 1080)
        let frame2 = createTestFrame(imageData: imageData2, width: 1920, height: 1080)

        measure {
            _ = deduplicator.computeSimilarity(frame1, frame2)
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Test Helpers                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Create test image data with pattern based on color (BGRA format)
    /// dHash requires spatial variation to work properly - solid colors produce hash of 0
    /// Different colors create different stripe patterns
    private func createTestImageData(width: Int, height: Int, color: UInt8) -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

            // Use color value to determine stripe width (varies pattern structure)
            let stripeWidth = max(5, Int(color) / 10)

            for y in 0..<height {
                for x in 0..<width {
                    // Create vertical stripes with width based on color
                    let isStripe = (x / stripeWidth) % 2 == 0
                    let pixelValue = isStripe ? color : UInt8(clamping: Int(color) + 80)

                    let offset = y * bytesPerRow + x * bytesPerPixel
                    pixels[offset] = pixelValue     // B
                    pixels[offset + 1] = pixelValue // G
                    pixels[offset + 2] = pixelValue // R
                    pixels[offset + 3] = 255        // A
                }
            }
        }

        return data
    }

    /// Create test image data with noise
    private func createTestImageDataWithNoise(width: Int, height: Int, baseColor: UInt8, noiseLevel: UInt8) -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let noise = Int8.random(in: -Int8(noiseLevel)...Int8(noiseLevel))
                    let pixelValue = UInt8(clamping: Int(baseColor) + Int(noise))

                    let offset = y * bytesPerRow + x * bytesPerPixel
                    pixels[offset] = pixelValue     // B
                    pixels[offset + 1] = pixelValue // G
                    pixels[offset + 2] = pixelValue // R
                    pixels[offset + 3] = 255        // A
                }
            }
        }

        return data
    }

    /// Create test frame
    private func createTestFrame(imageData: Data, width: Int, height: Int) -> CapturedFrame {
        let bytesPerRow = width * 4
        return CapturedFrame(
            timestamp: Date(),
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: .empty
        )
    }
}
