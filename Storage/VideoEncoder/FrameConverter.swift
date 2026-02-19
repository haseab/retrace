import CoreVideo
import CoreGraphics
import Foundation
import Shared

/// Converts CapturedFrame raw BGRA bytes into CVPixelBuffer.
enum FrameConverter {
    static func createPixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
        guard frame.width > 0, frame.height > 0 else {
            throw StorageModuleError.encodingFailed(underlying: "Invalid frame dimensions: \(frame.width)x\(frame.height)")
        }

        let (pixelDataPerRow, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else {
            throw StorageModuleError.encodingFailed(underlying: "Frame width overflow when computing BGRA bytesPerRow")
        }

        guard frame.bytesPerRow >= pixelDataPerRow else {
            throw StorageModuleError.encodingFailed(
                underlying: "Invalid source stride: \(frame.bytesPerRow) < required \(pixelDataPerRow)"
            )
        }

        let (requiredSourceBytes, sourceOverflow) = frame.bytesPerRow.multipliedReportingOverflow(by: frame.height)
        guard !sourceOverflow, frame.imageData.count >= requiredSourceBytes else {
            throw StorageModuleError.encodingFailed(
                underlying: "Frame data too small: \(frame.imageData.count) < required \(requiredSourceBytes)"
            )
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
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
        guard !CVPixelBufferIsPlanar(buffer) else {
            throw StorageModuleError.encodingFailed(underlying: "Unexpected planar pixel buffer for BGRA frame")
        }

        let destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let srcBytesPerRow = frame.bytesPerRow

        guard destBytesPerRow >= pixelDataPerRow else {
            throw StorageModuleError.encodingFailed(
                underlying: "Invalid destination stride: \(destBytesPerRow) < required \(pixelDataPerRow)"
            )
        }

        let (requiredDestBytes, destOverflow) = destBytesPerRow.multipliedReportingOverflow(by: frame.height)
        if !destOverflow {
            let destCapacity = CVPixelBufferGetDataSize(buffer)
            if destCapacity > 0 {
                guard destCapacity >= requiredDestBytes else {
                    throw StorageModuleError.encodingFailed(
                        underlying: "Destination buffer too small: \(destCapacity) < required \(requiredDestBytes)"
                    )
                }
            }
        }

        try frame.imageData.withUnsafeBytes { srcPtr in
            guard let srcBase = srcPtr.baseAddress else {
                throw StorageModuleError.encodingFailed(underlying: "Frame data base address is nil")
            }
            // Copy row-by-row to avoid stride/padding assumptions.
            for row in 0..<frame.height {
                let srcOffset = row * srcBytesPerRow
                let destOffset = row * destBytesPerRow

                guard srcOffset + pixelDataPerRow <= frame.imageData.count else {
                    throw StorageModuleError.encodingFailed(
                        underlying: "Source row \(row) out of bounds during pixel copy"
                    )
                }

                memcpy(
                    baseAddress.advanced(by: destOffset),
                    srcBase.advanced(by: srcOffset),
                    pixelDataPerRow
                )
            }
        }

        return buffer
    }
}
