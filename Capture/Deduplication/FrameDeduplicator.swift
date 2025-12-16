import Foundation
import Shared

/// Implementation of frame deduplication using perceptual hashing
/// Conforms to DeduplicationProtocol from Shared/Protocols
public struct FrameDeduplicator: DeduplicationProtocol {

    // MARK: - Initialization

    public init() {}

    // MARK: - DeduplicationProtocol

    /// Check if a frame should be kept based on similarity to reference frame
    /// - Parameters:
    ///   - frame: The new frame to evaluate
    ///   - reference: The reference frame to compare against (nil means always keep)
    ///   - threshold: Similarity threshold (0-1, higher = more strict, more frames filtered)
    /// - Returns: True if frame should be kept, false if it's too similar (duplicate)
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

        // Compute similarity
        let similarity = computeSimilarity(frame, reference)

        // Interpret threshold as minimum required dissimilarity
        // Higher threshold = more strict = more frames filtered
        // threshold 0.98 → keep if similarity < 0.02 (very strict, almost all filtered)
        // threshold 0.02 → keep if similarity < 0.98 (lenient, only identical filtered)
        let maxAllowedSimilarity = 1.0 - threshold
        return similarity < maxAllowedSimilarity
    }

    /// Compute a perceptual hash for a frame
    /// - Parameter frame: The frame to hash
    /// - Returns: 64-bit hash value
    public func computeHash(for frame: CapturedFrame) -> UInt64 {
        PerceptualHash.computeHash(for: frame)
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

        // Compute hashes
        let hash1 = computeHash(for: frame1)
        let hash2 = computeHash(for: frame2)

        // Compare hashes
        return PerceptualHash.computeSimilarity(hash1: hash1, hash2: hash2)
    }
}
