import Foundation
import Vision
import CoreGraphics
import Shared

// MARK: - VisionOCR

/// Vision framework implementation of OCRProtocol
public struct VisionOCR: OCRProtocol {

    public init() {}

    // MARK: - OCRProtocol

    public func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        // Create CGImage from raw pixel data
        guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
            throw ProcessingError.imageConversionFailed
        }

        // Create Vision text recognition request
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = config.ocrAccuracyLevel == .accurate ? .accurate : .fast
        request.recognitionLanguages = config.recognitionLanguages
        request.usesLanguageCorrection = true

        // Perform recognition
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([request])

                guard let observations = request.results else {
                    continuation.resume(returning: [])
                    return
                }

                // Convert observations to TextRegions
                let regions = observations.compactMap { observation -> TextRegion? in
                    // Filter by confidence threshold
                    guard observation.confidence >= config.minimumConfidence else { return nil }

                    // Extract text (top candidate)
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    let text = topCandidate.string

                    // Skip empty text
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                    // Get bounding box (normalized coordinates, origin bottom-left)
                    let box = observation.boundingBox

                    // Convert normalized coordinates to pixel coordinates
                    let pixelBox = CGRect(
                        x: box.origin.x * CGFloat(width),
                        y: box.origin.y * CGFloat(height),
                        width: box.width * CGFloat(width),
                        height: box.height * CGFloat(height)
                    )

                    return TextRegion(
                        frameID: FrameID(), // Placeholder - will be updated by caller
                        text: text,
                        bounds: pixelBox,
                        confidence: Double(observation.confidence)
                    )
                }

                continuation.resume(returning: regions)
            } catch {
                continuation.resume(throwing: ProcessingError.ocrFailed(underlying: error.localizedDescription))
            }
        }
    }

    // MARK: - Image Conversion

    /// Convert raw pixel data to CGImage for Vision framework
    /// Assumes BGRA format (typical from ScreenCaptureKit)
    private func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // BGRA format: premultiplied alpha, little endian
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,  // Use actual bytesPerRow (may include padding for alignment)
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
