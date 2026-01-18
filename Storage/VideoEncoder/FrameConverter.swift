import CoreVideo
import CoreGraphics
import Foundation
import Shared

/// Converts CapturedFrame raw BGRA bytes into CVPixelBuffer.
enum FrameConverter {
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
        let rowBytes = min(srcBytesPerRow, destBytesPerRow)

        frame.imageData.withUnsafeBytes { srcPtr in
            guard let srcBase = srcPtr.baseAddress else { return }

            // Copy row by row to handle bytesPerRow mismatch
            if srcBytesPerRow == destBytesPerRow {
                // Fast path: same stride, single memcpy
                memcpy(baseAddress, srcBase, min(frame.imageData.count, destBytesPerRow * frame.height))
            } else {
                // Slow path: copy row by row to handle stride difference
                for row in 0..<frame.height {
                    let srcOffset = row * srcBytesPerRow
                    let destOffset = row * destBytesPerRow
                    guard srcOffset + rowBytes <= frame.imageData.count else { break }
                    memcpy(baseAddress + destOffset, srcBase + srcOffset, rowBytes)
                }
            }
        }

        return buffer
    }
}
