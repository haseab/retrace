import Foundation
import Shared

/// Implementation of frame deduplication using simple pixel sampling
/// Conforms to DeduplicationProtocol from Shared/Protocols
public struct FrameDeduplicator: DeduplicationProtocol {

    // MARK: - Initialization

    public init() {}

    // MARK: - DeduplicationProtocol

    /// Check if a frame should be kept based on similarity to reference frame
    /// - Parameters:
    ///   - frame: The new frame to evaluate
    ///   - reference: The reference frame to compare against (nil means always keep)
    ///   - threshold: Similarity threshold (0-1, where 1.0 means identical)
    /// - Returns: True if frame should be kept, false if it's basically the same (duplicate)
    public func shouldKeepFrame(
        _ frame: CapturedFrame,
        comparedTo reference: CapturedFrame?,
        threshold: Double
    ) -> Bool {
        // Always keep if there's no reference
        guard let reference = reference else { return true }

        // Quick size check - if dimensions changed, definitely keep
        if frame.width != reference.width || frame.height != reference.height {
            return true
        }

        // Check if frames are basically identical
        let similarity = computeSimilarity(frame, reference)

        // If similarity is below threshold, keep the frame (it changed enough)
        // threshold 0.95 → keep if similarity < 0.95 (frames are different enough)
        return similarity < threshold
    }

    /// Compute a perceptual hash for a frame
    /// - Parameter frame: The frame to hash
    /// - Returns: 64-bit hash value
    public func computeHash(for frame: CapturedFrame) -> UInt64 {
        // Simple checksum of sampled pixels
        var hash: UInt64 = 0
        let sampleSize = 64

        frame.imageData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

            let totalPixels = frame.width * frame.height
            let step = max(1, totalPixels / sampleSize)

            for i in stride(from: 0, to: totalPixels, by: step).prefix(sampleSize) {
                let offset = i * 4
                if offset + 2 < frame.imageData.count {
                    let r = UInt64(pixels[offset + 2])
                    let g = UInt64(pixels[offset + 1])
                    let b = UInt64(pixels[offset])
                    hash = hash &+ (r &+ g &+ b)
                }
            }
        }

        return hash
    }

    /// Compute similarity score between two frames
    /// - Parameters:
    ///   - frame1: First frame
    ///   - frame2: Second frame
    /// - Returns: Similarity score from 0.0 (completely different) to 1.0 (identical)
    public func computeSimilarity(
        _ frame1: CapturedFrame,
        _ frame2: CapturedFrame
    ) -> Double {
        // Quick size check
        if frame1.width != frame2.width || frame1.height != frame2.height {
            return 0.0 // Completely different
        }

        // Sample pixels across the image and compare
        let sampleSize = 100 // Check 100 evenly-distributed pixels
        var matchingPixels = 0
        var totalSamples = 0

        frame1.imageData.withUnsafeBytes { bytes1 in
            frame2.imageData.withUnsafeBytes { bytes2 in
                guard let base1 = bytes1.baseAddress,
                      let base2 = bytes2.baseAddress else { return }

                let pixels1 = base1.assumingMemoryBound(to: UInt8.self)
                let pixels2 = base2.assumingMemoryBound(to: UInt8.self)

                let totalPixels = frame1.width * frame1.height
                let step = max(1, totalPixels / sampleSize)

                for i in stride(from: 0, to: totalPixels, by: step).prefix(sampleSize) {
                    let offset = i * 4
                    if offset + 2 < frame1.imageData.count && offset + 2 < frame2.imageData.count {
                        let r1 = pixels1[offset + 2]
                        let g1 = pixels1[offset + 1]
                        let b1 = pixels1[offset]

                        let r2 = pixels2[offset + 2]
                        let g2 = pixels2[offset + 1]
                        let b2 = pixels2[offset]

                        // Check if pixels are very similar (within 5% tolerance)
                        let rDiff = abs(Int(r1) - Int(r2))
                        let gDiff = abs(Int(g1) - Int(g2))
                        let bDiff = abs(Int(b1) - Int(b2))

                        if rDiff < 13 && gDiff < 13 && bDiff < 13 { // 13 ≈ 5% of 255
                            matchingPixels += 1
                        }
                        totalSamples += 1
                    }
                }
            }
        }

        guard totalSamples > 0 else { return 0.0 }
        return Double(matchingPixels) / Double(totalSamples)
    }
}
