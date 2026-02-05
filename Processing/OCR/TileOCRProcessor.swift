import Foundation
import Vision
import CoreGraphics
import Shared

/// Processes OCR on individual tiles using Vision's regionOfInterest
/// This avoids cropping images and lets Vision handle the region internally
public final class TileOCRProcessor: Sendable {
    private let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    /// Create a fresh VNRecognizeTextRequest for each tile
    /// This ensures thread safety when processing tiles concurrently
    private func createTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true
        return request
    }

    /// Run OCR on a single tile using regionOfInterest
    /// - Parameters:
    ///   - image: The full frame CGImage
    ///   - tile: The tile to process (contains normalized bounds for ROI)
    ///   - config: Processing configuration
    ///   - frameWidth: Full frame width in pixels
    ///   - frameHeight: Full frame height in pixels
    /// - Returns: TextRegions with bounds in full frame pixel coordinates
    public func recognizeTile(
        image: CGImage,
        tile: TileInfo,
        config: ProcessingConfig,
        frameWidth: Int,
        frameHeight: Int
    ) async throws -> [TextRegion] {
        // Create a fresh request for each tile to ensure thread safety
        let textRequest = createTextRequest()

        // Set region of interest to this tile's normalized bounds
        // Vision uses bottom-left origin, normalizedBounds already accounts for this
        textRequest.regionOfInterest = tile.normalizedBounds

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([textRequest])

                guard let observations = textRequest.results else {
                    continuation.resume(returning: [])
                    return
                }

                let regions = observations.compactMap { observation -> TextRegion? in
                    guard observation.confidence >= config.minimumConfidence else { return nil }
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    let text = topCandidate.string
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                    // Vision returns bounding box relative to the regionOfInterest
                    // We need to remap to full frame coordinates
                    let roiBox = observation.boundingBox

                    // The ROI box is in normalized coords (0-1) within the ROI
                    // First, convert to full-image normalized coordinates
                    let roi = tile.normalizedBounds

                    // Box position within full image (still in Vision's bottom-left origin)
                    let fullImageX = roi.origin.x + (roiBox.origin.x * roi.width)
                    let fullImageY = roi.origin.y + (roiBox.origin.y * roi.height)
                    let fullImageWidth = roiBox.width * roi.width
                    let fullImageHeight = roiBox.height * roi.height

                    // Flip Y from Vision's bottom-left to our top-left origin
                    // Vision: y=0 at bottom, y=1 at top
                    // Our coords: y=0 at top, y increases downward
                    let flippedY = 1.0 - fullImageY - fullImageHeight

                    // Convert normalized to pixel coordinates
                    let pixelBounds = CGRect(
                        x: fullImageX * CGFloat(frameWidth),
                        y: flippedY * CGFloat(frameHeight),
                        width: fullImageWidth * CGFloat(frameWidth),
                        height: fullImageHeight * CGFloat(frameHeight)
                    )

                    return TextRegion(
                        frameID: FrameID(value: 0), // Placeholder, updated by caller
                        text: text,
                        bounds: pixelBounds,
                        confidence: Double(observation.confidence)
                    )
                }

                continuation.resume(returning: regions)
            } catch {
                continuation.resume(throwing: ProcessingError.ocrFailed(underlying: error.localizedDescription))
            }
        }
    }

    /// Batch OCR multiple tiles concurrently
    /// - Parameters:
    ///   - image: The full frame CGImage
    ///   - tiles: Tiles to process
    ///   - config: Processing configuration
    ///   - frameWidth: Full frame width in pixels
    ///   - frameHeight: Full frame height in pixels
    /// - Returns: Dictionary mapping tile cacheKey to TextRegions
    public func recognizeTiles(
        image: CGImage,
        tiles: [TileInfo],
        config: ProcessingConfig,
        frameWidth: Int,
        frameHeight: Int
    ) async throws -> [String: [TextRegion]] {
        // Process tiles concurrently using task group
        // Vision handles internal parallelism efficiently
        var results: [String: [TextRegion]] = [:]

        // Use a reasonable concurrency limit to avoid overwhelming the system
        // Vision's ANE can handle parallel requests but too many cause contention
        let batchSize = min(tiles.count, 8)

        for batchStart in stride(from: 0, to: tiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, tiles.count)
            let batch = Array(tiles[batchStart..<batchEnd])

            try await withThrowingTaskGroup(of: (String, [TextRegion]).self) { group in
                for tile in batch {
                    group.addTask {
                        let regions = try await self.recognizeTile(
                            image: image,
                            tile: tile,
                            config: config,
                            frameWidth: frameWidth,
                            frameHeight: frameHeight
                        )
                        return (tile.cacheKey, regions)
                    }
                }

                for try await (key, regions) in group {
                    results[key] = regions
                }
            }
        }

        return results
    }
}
