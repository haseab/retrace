import Foundation
import Vision
import CoreGraphics
import Accelerate
import Shared

// MARK: - VisionOCR

/// Vision framework implementation of OCRProtocol
public final class VisionOCR: OCRProtocol, @unchecked Sendable {

    /// Recognition languages for OCR
    private let recognitionLanguages: [String]

    /// OCR scale settings for adaptive downscaling.
    /// Frames above the target megapixel budget are downscaled to cap OCR cost.
    private static let maxOCRScaleFactor: CGFloat = 1.0
    private static let minOCRScaleFactor: CGFloat = 0.55
    private static let targetMegapixelsAccurate: CGFloat = 3.0
    private static let targetMegapixelsFast: CGFloat = 4.0

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        // Create a fresh request per call for thread safety with concurrent workers
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = Self.recognitionLevel(for: config)
        textRequest.recognitionLanguages = recognitionLanguages
        textRequest.usesLanguageCorrection = false
        textRequest.preferBackgroundProcessing = config.preferBackgroundProcessing

        // Create CGImage from raw pixel data
        guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
            throw ProcessingError.imageConversionFailed
        }

        let ocrImage: CGImage
        let ocrScaleFactor = Self.calculateOCRScaleFactor(
            width: width,
            height: height,
            config: config
        )
        if ocrScaleFactor < Self.maxOCRScaleFactor {
            ocrImage = downscaleImage(cgImage, scale: ocrScaleFactor) ?? cgImage
        } else {
            ocrImage = cgImage
        }

        // Perform recognition with per-call request
        let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([textRequest])

                guard let observations = textRequest.results else {
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

                    // CRITICAL: Flip Y coordinate from Vision's bottom-left origin to top-left origin
                    // Vision: y=0 at bottom, y=1 at top
                    // Rewind/Screen: y=0 at top, y=1 at bottom
                    // Formula: flippedY = 1.0 - visionY - visionHeight
                    let flippedY = 1.0 - box.origin.y - box.height

                    // Convert normalized coordinates to pixel coordinates (with flipped Y)
                    let pixelBox = CGRect(
                        x: box.origin.x * CGFloat(width),
                        y: flippedY * CGFloat(height),
                        width: box.width * CGFloat(width),
                        height: box.height * CGFloat(height)
                    )

                    return TextRegion(
                        frameID: FrameID(value: 0), // Placeholder - will be updated by caller
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

    // MARK: - Live Screenshot OCR

    /// Perform OCR directly on a CGImage (for live screenshot use case)
    /// Uses the same .accurate pipeline as frame processing
    /// Returns TextRegions with **normalized coordinates** (0.0-1.0) for direct use with OCRNodeWithText
    public func recognizeTextFromCGImage(_ cgImage: CGImage) async throws -> [TextRegion] {
        // No downscaling for live screenshot - it's a one-shot operation
        // and downscaling can introduce subtle bounding box drift from integer rounding
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = recognitionLanguages
        textRequest.usesLanguageCorrection = true

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([textRequest])

                guard let observations = textRequest.results else {
                    continuation.resume(returning: [])
                    return
                }

                let regions = observations.compactMap { observation -> TextRegion? in
                    guard observation.confidence >= 0.5 else { return nil }
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    let text = topCandidate.string
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                    let box = observation.boundingBox

                    // Flip Y from Vision's bottom-left origin to top-left origin
                    let flippedY = 1.0 - box.origin.y - box.height

                    // Return NORMALIZED coordinates (0.0-1.0) for OCRNodeWithText
                    let normalizedBox = CGRect(
                        x: box.origin.x,
                        y: flippedY,
                        width: box.width,
                        height: box.height
                    )

                    return TextRegion(
                        frameID: FrameID(value: 0),
                        text: text,
                        bounds: normalizedBox,
                        confidence: Double(observation.confidence)
                    )
                }

                continuation.resume(returning: regions)
            } catch {
                continuation.resume(throwing: ProcessingError.ocrFailed(underlying: error.localizedDescription))
            }
        }
    }

    // MARK: - Image Processing

    /// Downscale a CGImage using vImage (hardware-accelerated, high quality)
    /// Returns nil if downscaling fails, caller should fall back to original image
    private func downscaleImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let newWidth = Int(CGFloat(image.width) * scale)
        let newHeight = Int(CGFloat(image.height) * scale)

        guard newWidth > 0, newHeight > 0 else { return nil }

        // Create source vImage buffer from CGImage
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,  // Uses image's color space
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }

        // Create destination buffer
        var destBuffer = vImage_Buffer()
        error = vImageBuffer_Init(&destBuffer, vImagePixelCount(newHeight), vImagePixelCount(newWidth), 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(destBuffer.data) }

        // Scale using high-quality Lanczos resampling
        error = vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { return nil }

        // Create CGImage from scaled buffer
        return vImageCreateCGImageFromBuffer(&destBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }

    // MARK: - Region-Based OCR

    /// Region-based OCR - uses tiles for CHANGE DETECTION only, not for OCR bounding boxes
    /// Preserves paragraph-level bounding boxes from full-frame OCR
    /// Only re-OCRs regions that touch changed tiles
    ///
    /// - Parameters:
    ///   - frame: Current frame to process
    ///   - previousFrame: Previous frame for change detection (nil = full OCR)
    ///   - cache: Full-frame OCR cache for storing/retrieving results
    ///   - config: Processing configuration
    /// - Returns: RegionOCRResult with merged regions and statistics
    public func recognizeTextRegionBased(
        frame: CapturedFrame,
        previousFrame: CapturedFrame?,
        cache: FullFrameOCRCache,
        config: ProcessingConfig
    ) async throws -> RegionOCRResult {
        let totalStartTime = Date()

        // Check if cache is valid for this frame (resolution/app change invalidates)
        let cacheInvalidated = await cache.validateForFrame(
            width: frame.width,
            height: frame.height,
            appBundleID: frame.metadata.appBundleID
        )

        let tileConfig = TileGridConfig.default
        let changeDetector = TileChangeDetector(config: tileConfig)

        // Check if we have cached regions (must await before condition)
        let hasCached = await cache.hasCachedRegions()

        // If cache was invalidated or no previous frame, do full-frame OCR
        if cacheInvalidated || previousFrame == nil || !hasCached {
            let ocrStartTime = Date()

            // Do standard full-frame OCR (preserves paragraph-level bounding boxes)
            let regions = try await recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config
            )
            let ocrTime = Date().timeIntervalSince(ocrStartTime) * 1000

            // Create tile grid and store in cache for future change detection
            let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
            await cache.setFullFrameResults(regions: regions, tileGrid: allTiles)

            return RegionOCRResult(
                regions: regions,
                stats: RegionOCRStats(
                    tilesOCRed: allTiles.count,
                    tilesCached: 0,
                    totalTiles: allTiles.count,
                    changeDetectionTimeMs: 0,
                    ocrTimeMs: ocrTime,
                    mergeTimeMs: 0
                )
            )
        }

        // Detect changed tiles using original frame dimensions
        guard let changeResult = changeDetector.detectChanges(
            current: frame,
            previous: previousFrame!
        ) else {
            // Dimensions changed (shouldn't happen after validation, but handle gracefully)
            let regions = try await recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config
            )
            let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
            await cache.setFullFrameResults(regions: regions, tileGrid: allTiles)
            return RegionOCRResult(
                regions: regions,
                stats: RegionOCRStats.fullFrame(
                    totalTiles: allTiles.count,
                    ocrTimeMs: Date().timeIntervalSince(totalStartTime) * 1000
                )
            )
        }

        // If nothing changed, return all cached results
        if changeResult.changedTiles.isEmpty {
            let cachedRegions = await cache.getCachedRegions()

            return RegionOCRResult(
                regions: cachedRegions,
                stats: RegionOCRStats(
                    tilesOCRed: 0,
                    tilesCached: changeResult.totalTiles,
                    totalTiles: changeResult.totalTiles,
                    changeDetectionTimeMs: changeResult.detectionTimeMs,
                    ocrTimeMs: 0,
                    mergeTimeMs: 0
                )
            )
        }

        // Find which cached regions are affected by the changed tiles
        // Any region that intersects a changed tile needs to be re-OCR'd
        // We don't need to expand to adjacent tiles - if text moved there, those tiles would also be changed
        let (_, unaffectedRegions) = await cache.findAffectedRegions(changedTiles: changeResult.changedTiles)

        // Calculate the bounding box covering changed tiles only
        let reOCRBounds = calculateBoundingBox(for: changeResult.changedTiles)

        // Perform OCR only on the affected region using regionOfInterest
        let ocrStartTime = Date()
        let newRegions = try await recognizeTextInRegion(
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            region: reOCRBounds,
            config: config
        )
        let ocrTime = Date().timeIntervalSince(ocrStartTime) * 1000

        // Merge unaffected cached regions with new OCR results
        // Key insight: if a new region overlaps with an unaffected cached region,
        // the cached region likely has the full paragraph text while the new one
        // only has a partial view. Keep the cached version in that case.
        let mergeStartTime = Date()

        // Filter out new regions that overlap significantly with unaffected cached regions
        let filteredNewRegions = newRegions.filter { newRegion in
            // Check if this new region overlaps with any unaffected cached region
            let overlapsWithCached = unaffectedRegions.contains { cachedRegion in
                boundsOverlapSignificantly(newRegion.bounds, cachedRegion.bounds)
            }
            // Keep the new region only if it doesn't overlap with cached
            return !overlapsWithCached
        }

        var mergedRegions = unaffectedRegions + filteredNewRegions

        // Sort by reading order: top-to-bottom, then left-to-right
        mergedRegions.sort { a, b in
            if abs(a.bounds.origin.y - b.bounds.origin.y) < 20 {
                return a.bounds.origin.x < b.bounds.origin.x
            }
            return a.bounds.origin.y < b.bounds.origin.y
        }
        let mergeTime = Date().timeIntervalSince(mergeStartTime) * 1000

        // Update cache with merged results
        let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
        await cache.setFullFrameResults(regions: mergedRegions, tileGrid: allTiles)

        return RegionOCRResult(
            regions: mergedRegions,
            stats: RegionOCRStats(
                tilesOCRed: changeResult.changedTiles.count,
                tilesCached: changeResult.unchangedTiles.count,
                totalTiles: changeResult.totalTiles,
                changeDetectionTimeMs: changeResult.detectionTimeMs,
                ocrTimeMs: ocrTime,
                mergeTimeMs: mergeTime
            )
        )
    }

    /// Check if two rectangles overlap by more than 30%
    /// Used to detect when a new partial region overlaps with a cached full region
    private func boundsOverlapSignificantly(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)

        guard smallerArea > 0 else { return false }

        // 30% overlap threshold - if significant portion overlaps, they're likely the same text
        return intersectionArea / smallerArea > 0.3
    }

    /// Calculate the bounding box that covers all given tiles
    private func calculateBoundingBox(for tiles: [TileInfo]) -> CGRect {
        guard !tiles.isEmpty else { return .zero }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = CGFloat.zero
        var maxY = CGFloat.zero

        for tile in tiles {
            minX = min(minX, tile.pixelBounds.minX)
            minY = min(minY, tile.pixelBounds.minY)
            maxX = max(maxX, tile.pixelBounds.maxX)
            maxY = max(maxY, tile.pixelBounds.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Perform OCR on a specific region of the frame using regionOfInterest
    /// Returns TextRegions with bounds in full frame coordinates
    private func recognizeTextInRegion(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        region: CGRect,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        // If region covers the full frame, use standard OCR
        if region.minX <= 0 && region.minY <= 0 &&
           region.maxX >= CGFloat(width) && region.maxY >= CGFloat(height) {
            return try await recognizeText(
                imageData: imageData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                config: config
            )
        }

        // Create CGImage from raw pixel data
        guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
            throw ProcessingError.imageConversionFailed
        }

        let ocrImage: CGImage
        let ocrScaleFactor = Self.calculateOCRScaleFactor(
            width: width,
            height: height,
            config: config
        )
        if ocrScaleFactor < Self.maxOCRScaleFactor {
            ocrImage = downscaleImage(cgImage, scale: ocrScaleFactor) ?? cgImage
        } else {
            ocrImage = cgImage
        }

        // Convert pixel region to normalized coordinates for Vision
        // Vision uses bottom-left origin (y=0 at bottom)
        let normalizedX = region.minX / CGFloat(width)
        let normalizedWidth = region.width / CGFloat(width)
        let normalizedHeight = region.height / CGFloat(height)
        // Flip Y: our y=0 at top, Vision y=0 at bottom
        let normalizedY = 1.0 - (region.maxY / CGFloat(height))

        let normalizedRegion = CGRect(
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight
        )

        // Create a fresh request with regionOfInterest
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = Self.recognitionLevel(for: config)
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = config.ocrAccuracyLevel == .accurate
        request.regionOfInterest = normalizedRegion

        let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try handler.perform([request])

                guard let observations = request.results else {
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

                    // Convert ROI-relative coords to full-image normalized coords
                    let fullImageX = normalizedRegion.origin.x + (roiBox.origin.x * normalizedRegion.width)
                    let fullImageY = normalizedRegion.origin.y + (roiBox.origin.y * normalizedRegion.height)
                    let fullImageWidth = roiBox.width * normalizedRegion.width
                    let fullImageHeight = roiBox.height * normalizedRegion.height

                    // Flip Y from Vision's bottom-left to our top-left origin
                    let flippedY = 1.0 - fullImageY - fullImageHeight

                    // Convert normalized to pixel coordinates
                    let pixelBounds = CGRect(
                        x: fullImageX * CGFloat(width),
                        y: flippedY * CGFloat(height),
                        width: fullImageWidth * CGFloat(width),
                        height: fullImageHeight * CGFloat(height)
                    )

                    return TextRegion(
                        frameID: FrameID(value: 0),
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

    /// Map app OCR config to Vision recognition mode.
    private static func recognitionLevel(for config: ProcessingConfig) -> VNRequestTextRecognitionLevel {
        switch config.ocrAccuracyLevel {
        case .fast:
            return .fast
        case .accurate:
            return .accurate
        }
    }

    /// Compute an adaptive OCR scale based on frame size.
    /// This caps OCR pixel workload on large/ultrawide displays to reduce CPU spikes.
    private static func calculateOCRScaleFactor(
        width: Int,
        height: Int,
        config: ProcessingConfig
    ) -> CGFloat {
        guard width > 0, height > 0 else { return maxOCRScaleFactor }

        let frameMegapixels = (CGFloat(width) * CGFloat(height)) / 1_000_000.0
        let targetMegapixels: CGFloat = (config.ocrAccuracyLevel == .fast) ? targetMegapixelsFast : targetMegapixelsAccurate

        guard frameMegapixels > targetMegapixels else {
            return maxOCRScaleFactor
        }

        // Keep OCR near the target megapixel budget: scale^2 * frameMP ~= targetMP.
        let scale = sqrt(targetMegapixels / frameMegapixels)
        return min(maxOCRScaleFactor, max(minOCRScaleFactor, scale))
    }

    /// Create a CapturedFrame-like structure from a CGImage for change detection
    private func createScaledFrame(from cgImage: CGImage, originalFrame: CapturedFrame) -> CapturedFrame {
        // Extract pixel data from CGImage
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        var pixelData = Data(count: dataSize)
        pixelData.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return CapturedFrame(
            timestamp: originalFrame.timestamp,
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: originalFrame.metadata
        )
    }

    // MARK: - Image Conversion

    /// Convert raw pixel data to CGImage for Vision framework
    /// Assumes BGRA format (typical from ScreenCaptureKit)
    func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
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
