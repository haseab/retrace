import Foundation
import Accelerate
import Shared

/// Perceptual hashing implementation using difference hash (dHash)
/// Used for fast image similarity comparison
struct PerceptualHash: Sendable {

    // MARK: - Hash Computation

    /// Compute a 64-bit perceptual hash for a frame using difference hash (dHash)
    /// - Parameter frame: The frame to hash
    /// - Returns: 64-bit hash value
    static func computeHash(for frame: CapturedFrame) -> UInt64 {
        // Resize to 9x8 (we need 9 cols to compute 8 differences per row)
        let resizedWidth = 9
        let resizedHeight = 8
        let resized = resizeToGrayscale(
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            targetWidth: resizedWidth,
            targetHeight: resizedHeight
        )

        // Compute difference hash
        var hash: UInt64 = 0
        var bitPosition = 0

        for row in 0..<resizedHeight {
            for col in 0..<(resizedWidth - 1) {
                let leftPixel = resized[row * resizedWidth + col]
                let rightPixel = resized[row * resizedWidth + col + 1]

                // Set bit if left pixel is brighter than right pixel
                if leftPixel > rightPixel {
                    hash |= (1 << bitPosition)
                }
                bitPosition += 1
            }
        }

        return hash
    }

    /// Compute similarity between two hashes using Hamming distance
    /// - Parameters:
    ///   - hash1: First hash
    ///   - hash2: Second hash
    /// - Returns: Similarity score from 0.0 (completely different) to 1.0 (identical)
    static func computeSimilarity(hash1: UInt64, hash2: UInt64) -> Double {
        // XOR to find differing bits
        let xor = hash1 ^ hash2

        // Count differing bits (Hamming distance)
        let differentBits = xor.nonzeroBitCount

        // Convert to similarity (0 differences = 1.0 similarity)
        return 1.0 - (Double(differentBits) / 64.0)
    }

    // MARK: - Image Processing

    /// Resize image to target size and convert to grayscale
    /// Uses nearest-neighbor interpolation for speed
    private static func resizeToGrayscale(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8] {
        // Create output buffer
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight)

        // Compute scale factors
        let scaleX = Double(width) / Double(targetWidth)
        let scaleY = Double(height) / Double(targetHeight)

        imageData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in 0..<targetHeight {
                for x in 0..<targetWidth {
                    // Find source pixel using nearest-neighbor
                    let srcXDouble = Double(x) * scaleX
                    let srcYDouble = Double(y) * scaleY
                    let srcX = Int(srcXDouble)
                    let srcY = Int(srcYDouble)

                    // Calculate source pixel position (BGRA format)
                    let srcOffset = srcY * bytesPerRow + srcX * 4

                    // Get BGR values (format is BGRA)
                    let b = pixels[srcOffset]
                    let g = pixels[srcOffset + 1]
                    let r = pixels[srcOffset + 2]

                    // Convert to grayscale using standard formula
                    // Gray = 0.299R + 0.587G + 0.114B
                    let rVal = UInt32(r)
                    let gVal = UInt32(g)
                    let bVal = UInt32(b)
                    let grayValue = (299 * rVal + 587 * gVal + 114 * bVal) / 1000
                    let gray = UInt8(grayValue)

                    output[y * targetWidth + x] = gray
                }
            }
        }

        return output
    }

    /// Alternative: Resize using vImage for better quality (slower)
    /// This could be used for more accurate hashing if needed
    /// - Note: Currently unimplemented, returns nil
    private static func resizeToGrayscaleVImage(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        // Uncommenting this implementation would require:
        // 1. Converting BGRA to grayscale format
        // 2. Using vImageScale_Planar8 for the resize operation
        // For now, we use the faster nearest-neighbor approach above

        // Example structure (currently unused):
        // var sourceBuffer = vImage_Buffer(...)
        // var destData = [UInt8](...)
        // var destBuffer = vImage_Buffer(...)

        return nil
    }
}
