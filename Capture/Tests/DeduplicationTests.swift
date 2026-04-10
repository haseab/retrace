import XCTest
import Shared
import CoreGraphics
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

        // The pixel-grid sampler should report relatively low similarity for different patterns
        XCTAssertLessThan(similarity, 0.8, "Different stripe patterns should have lower similarity")
    }

    func testComputeSimilarity_SlightlyDifferent_ReturnsHigh() {
        // Create two images with identical pattern structure (same stripe width)
        let imageData1 = createTestImageData(width: 100, height: 100, color: 120)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 121) // identical stripe width (both 12)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        // The pixel-grid sampler focuses on local similarity, so identical patterns should match well
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

        // Identical frames have similarity 1.0, which exceeds the allowed threshold and gets filtered
        let shouldKeep = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.98)

        XCTAssertFalse(shouldKeep, "Should filter identical frames with high threshold")
    }

    func testShouldKeepFrame_DifferentFrames_LowThreshold_ReturnsTrue() {
        let imageData1 = createTestImageData(width: 100, height: 100, color: 50)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 200)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        // Low threshold (0.02) is strict, but very different frames still stay below it and are kept
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

    func testThresholdSemantics_HigherKeepsMoreSimilarFrames() {
        // Create two frames with different stripe patterns
        // color 80 → stripe width 8
        // color 150 → stripe width 15 (significantly different pattern)
        let imageData1 = createTestImageData(width: 100, height: 100, color: 80)
        let imageData2 = createTestImageData(width: 100, height: 100, color: 150)

        let frame1 = createTestFrame(imageData: imageData1, width: 100, height: 100)
        let frame2 = createTestFrame(imageData: imageData2, width: 100, height: 100)

        let similarity = deduplicator.computeSimilarity(frame1, frame2)

        // These should overlap enough to be non-zero, but remain far from identical
        XCTAssertGreaterThan(similarity, 0.0, "Test frames should share some sampled pixels")
        XCTAssertLessThan(similarity, 1.0, "Test frames should not be identical (<1.0)")

        // Low threshold is stricter: only very different frames are kept
        let shouldKeepLowThreshold = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.02)
        XCTAssertFalse(shouldKeepLowThreshold, "Low threshold should filter moderately similar frames")

        // High threshold is more lenient: moderately similar frames are still kept
        let shouldKeepHighThreshold = deduplicator.shouldKeepFrame(frame2, comparedTo: frame1, threshold: 0.98)
        XCTAssertTrue(shouldKeepHighThreshold, "High threshold should keep moderately similar frames")

        // Verify: higher thresholds keep more frames under the current similarity semantics
        XCTAssertFalse(shouldKeepLowThreshold, "Low threshold filters frames")
        XCTAssertTrue(shouldKeepHighThreshold, "High threshold keeps frames")
    }

    func testShouldKeepFrameForMouseMovement_Disabled_ReturnsFalse() {
        let shouldKeep = CaptureManager.shouldKeepFrameForMouseMovement(
            enabled: false,
            previousMousePosition: CGPoint(x: 10, y: 10),
            currentMousePosition: CGPoint(x: 100, y: 100)
        )

        XCTAssertFalse(shouldKeep, "Mouse movement bypass should be disabled when setting is off")
    }

    func testShouldKeepFrameForMouseMovement_CursorEnteredFrame_ReturnsTrue() {
        let shouldKeep = CaptureManager.shouldKeepFrameForMouseMovement(
            enabled: true,
            previousMousePosition: nil,
            currentMousePosition: CGPoint(x: 50, y: 25)
        )

        XCTAssertTrue(shouldKeep, "Frame should be kept when cursor appears in captured display")
    }

    func testShouldKeepFrameForMouseMovement_BelowThreshold_ReturnsFalse() {
        let shouldKeep = CaptureManager.shouldKeepFrameForMouseMovement(
            enabled: true,
            previousMousePosition: CGPoint(x: 20, y: 20),
            currentMousePosition: CGPoint(x: 20.2, y: 20.2),
            minimumMovementPoints: 1.0
        )

        XCTAssertFalse(shouldKeep, "Tiny movement should not bypass deduplication")
    }

    func testShouldKeepFrameForMouseMovement_AtThreshold_ReturnsTrue() {
        let shouldKeep = CaptureManager.shouldKeepFrameForMouseMovement(
            enabled: true,
            previousMousePosition: CGPoint(x: 1, y: 1),
            currentMousePosition: CGPoint(x: 2, y: 1),
            minimumMovementPoints: 1.0
        )

        XCTAssertTrue(shouldKeep, "Movement at threshold should keep frame")
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
    /// Similarity sampling requires spatial variation - solid colors collapse into identical samples
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
