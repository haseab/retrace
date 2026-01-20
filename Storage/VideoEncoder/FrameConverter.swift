import CoreVideo
import CoreGraphics
import Foundation
import Shared

/// Converts CapturedFrame raw BGRA bytes into CVPixelBuffer.
enum FrameConverter {
    private static var hasLoggedMismatch = false
    static func createPixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferBytesPerRowAlignmentKey as String: frame.bytesPerRow
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw StorageModuleError.encodingFailed(underlying: "CVPixelBufferCreate failed: \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw StorageModuleError.encodingFailed(underlying: "PixelBuffer base address nil")
        }

        // Get the actual bytesPerRow of the CVPixelBuffer (may differ from frame.bytesPerRow due to alignment)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let srcBytesPerRow = frame.bytesPerRow

        // The actual pixel data per row is width * 4 bytes (BGRA)
        // bytesPerRow may include padding for alignment
        let pixelDataPerRow = frame.width * 4

        // Log frame info once for debugging
        if !hasLoggedMismatch {
            hasLoggedMismatch = true
            let hasMismatch = srcBytesPerRow != pixelDataPerRow || destBytesPerRow != pixelDataPerRow
            Log.info("[FrameConverter] First frame: src=\(srcBytesPerRow), dest=\(destBytesPerRow), pixelData=\(pixelDataPerRow), width=\(frame.width), height=\(frame.height), dataSize=\(frame.imageData.count), mismatch=\(hasMismatch)", category: .storage)
        }

        frame.imageData.withUnsafeBytes { srcPtr in
            guard let srcBase = srcPtr.baseAddress else { return }

            // Copy row by row to handle bytesPerRow mismatch
            // Always copy only the actual pixel data (width * 4), not the padding
            // Fast path only when ALL strides match AND equal actual pixel width
            let canUseFastPath = srcBytesPerRow == destBytesPerRow &&
                                 srcBytesPerRow == pixelDataPerRow &&
                                 frame.imageData.count == pixelDataPerRow * frame.height

            if canUseFastPath {
                // Fast path: no padding anywhere, single memcpy
                memcpy(baseAddress, srcBase, frame.imageData.count)
            } else {
                // Slow path: copy row by row, reading only actual pixel data
                for row in 0..<frame.height {
                    let srcOffset = row * srcBytesPerRow
                    let destOffset = row * destBytesPerRow
                    guard srcOffset + pixelDataPerRow <= frame.imageData.count else { break }
                    memcpy(baseAddress + destOffset, srcBase + srcOffset, pixelDataPerRow)
                }
            }
        }

        return buffer
    }
}
