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

        frame.imageData.withUnsafeBytes { srcPtr in
            guard let srcBase = srcPtr.baseAddress else { return }
            memcpy(baseAddress, srcBase, min(frame.imageData.count, frame.bytesPerRow * frame.height))
        }

        return buffer
    }
}
