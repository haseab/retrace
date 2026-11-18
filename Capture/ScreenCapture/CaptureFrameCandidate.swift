import Foundation
import CoreGraphics
import Shared

/// Privacy-filtered native image, materialized only after an exact-duplicate check.
/// Perceptual comparisons still use the established BGRA renderer and threshold.
struct CaptureFrameCandidate: Sendable {
    let image: CGImage?
    let timestamp: Date
    let metadata: FrameMetadata
    let accessibilitySnapshot: AccessibilitySnapshot?
    private let existingFrame: CapturedFrame?

    init(image: CGImage, timestamp: Date, metadata: FrameMetadata, accessibilitySnapshot: AccessibilitySnapshot? = nil) {
        self.accessibilitySnapshot = accessibilitySnapshot
        self.image = image
        self.timestamp = timestamp
        self.metadata = metadata
        self.existingFrame = nil
    }

    init(frame: CapturedFrame) {
        accessibilitySnapshot = frame.accessibilitySnapshot
        image = nil
        timestamp = frame.timestamp
        metadata = frame.metadata
        existingFrame = frame
    }

    var retainedImageBytes: Int64 { image.map { Int64($0.bytesPerRow) * Int64($0.height) } ?? 0 }

    func hasIdenticalPixels(to reference: CaptureFrameCandidate) -> Bool {
        guard let image, let other = reference.image,
              image.width == other.width, image.height == other.height,
              image.bytesPerRow == other.bytesPerRow,
              image.bitsPerPixel == other.bitsPerPixel,
              image.bitsPerComponent == other.bitsPerComponent,
              image.bitmapInfo == other.bitmapInfo,
              image.renderingIntent == other.renderingIntent,
              image.shouldInterpolate == other.shouldInterpolate,
              !image.isMask, !other.isMask,
              image.alphaInfo == other.alphaInfo,
              image.colorSpace == other.colorSpace,
              image.decode == nil, other.decode == nil,
              let bytes = image.dataProvider?.data,
              let previousBytes = other.dataProvider?.data else { return false }
        return CFEqual(bytes, previousBytes)
    }

    func materialize(reusingPixels pixels: Data? = nil) -> CapturedFrame? {
        if let existingFrame { return existingFrame }
        guard let image, let data = pixels ?? Self.convertCGImageToBGRAData(image) else { return nil }
        return CapturedFrame(timestamp: timestamp, imageData: data, width: image.width,
                             height: image.height, bytesPerRow: image.width * 4, metadata: metadata, accessibilitySnapshot: accessibilitySnapshot)
    }

    private static func convertCGImageToBGRAData(_ cgImage: CGImage) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4 // BGRA = 4 bytes per pixel
        let dataSize = bytesPerRow * height

        // Allocate buffer
        var pixelData = Data(count: dataSize)

        // Create bitmap context and draw within the same closure to ensure pointer validity
        let success = pixelData.withUnsafeMutableBytes { rawBufferPointer -> Bool in
            guard let baseAddress = rawBufferPointer.baseAddress else { return false }

            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return false
            }

            // Draw the image into the context (converts to BGRA)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? pixelData : nil
    }

}
