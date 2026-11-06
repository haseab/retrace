import CoreGraphics
import CoreImage
import Foundation
import Vision

enum ConferenceFaceBlurProcessorError: Error, Sendable {
    case renderingContextCreationFailed
    case blurredImageCreationFailed
    case outputImageCreationFailed
}

struct ConferenceFaceBlurConfiguration: Sendable {
    enum ExtraROIPolicy: String, Sendable {
        case disabled
        case whenBaseRegionIsLarge
        case always
    }

    let extraROIPolicy: ExtraROIPolicy
    let minimumBaseRegionShortEdgePixels: CGFloat
    let quadrantOverlapFraction: CGFloat
    let includeCenterSquare: Bool
    /// Normalized to the current base ROI, not the full image.
    let centerSquareLocalROI: CGRect
    let mergeOverlapThreshold: CGFloat

    static let production = ConferenceFaceBlurConfiguration(
        extraROIPolicy: .whenBaseRegionIsLarge,
        minimumBaseRegionShortEdgePixels: 520,
        quadrantOverlapFraction: 0.08,
        includeCenterSquare: true,
        centerSquareLocalROI: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
        mergeOverlapThreshold: 0.55
    )

    static let inspectorSinglePass = ConferenceFaceBlurConfiguration(
        extraROIPolicy: .disabled,
        minimumBaseRegionShortEdgePixels: .greatestFiniteMagnitude,
        quadrantOverlapFraction: 0.08,
        includeCenterSquare: false,
        centerSquareLocalROI: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
        mergeOverlapThreshold: 0.55
    )
}

struct ConferenceFaceBlurResult: Sendable {
    let blurredImage: CGImage?
    let faceCount: Int
    let detectionDurationMs: Double
    let detectionMode: DetectionMode
    let normalizedFaceRects: [CGRect]
    let maskRects: [CGRect]

    enum DetectionMode: String, Sendable {
        case fullFrame = "full_frame"
        case regionOfInterest = "region_of_interest"
        case multiPassFullFrame = "multi_pass_full_frame"
        case multiPassRegionOfInterest = "multi_pass_region_of_interest"
    }
}

actor ConferenceFaceBlurProcessor {
    private let ciContext = CIContext()

    func blurFaces(
        in image: CGImage,
        regionOfInterest: CGRect?,
        configuration: ConferenceFaceBlurConfiguration = .production
    ) async throws -> ConferenceFaceBlurResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let baseRegionOfInterest = Self.sanitizeRegionOfInterest(regionOfInterest)
        let requestRegions = Self.detectionRequestRegions(
            baseRegionOfInterest: baseRegionOfInterest,
            imageWidth: image.width,
            imageHeight: image.height,
            configuration: configuration
        )
        let detectionMode = Self.detectionMode(
            baseRegionOfInterest: baseRegionOfInterest,
            requestCount: requestRegions.count
        )
        let detectedRects = try performDetectionPasses(
            in: image,
            requestRegionsOfInterest: requestRegions
        )
        let mergedDetections = Self.mergedDetections(
            detectedRects,
            overlapThreshold: configuration.mergeOverlapThreshold
        )
        let expandedFaceRects = expandedFaceRects(
            from: mergedDetections,
            image: image
        )
        let maskRects = expandedFaceRects.map(circularMaskRect(for:))
        let detectionDurationMs = max(0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

        guard !maskRects.isEmpty else {
            return ConferenceFaceBlurResult(
                blurredImage: nil,
                faceCount: 0,
                detectionDurationMs: detectionDurationMs,
                detectionMode: detectionMode,
                normalizedFaceRects: mergedDetections,
                maskRects: []
            )
        }

        guard let output = try applyBlurMasks(
            in: image,
            maskRects: maskRects
        ) else {
            throw ConferenceFaceBlurProcessorError.outputImageCreationFailed
        }

        return ConferenceFaceBlurResult(
            blurredImage: output,
            faceCount: mergedDetections.count,
            detectionDurationMs: detectionDurationMs,
            detectionMode: detectionMode,
            normalizedFaceRects: mergedDetections,
            maskRects: maskRects
        )
    }

    func applyBlurMasks(
        in image: CGImage,
        maskRects: [CGRect]
    ) throws -> CGImage? {
        guard !maskRects.isEmpty else {
            return nil
        }

        guard let blurredImage = makeBlurredImage(from: image, faceRects: maskRects) else {
            throw ConferenceFaceBlurProcessorError.blurredImageCreationFailed
        }

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ConferenceFaceBlurProcessorError.renderingContextCreationFailed
        }

        let fullImageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: fullImageRect)
        context.saveGState()
        for circularMaskRect in maskRects {
            context.addPath(
                CGPath(ellipseIn: circularMaskRect, transform: nil)
            )
        }
        context.clip()
        context.draw(blurredImage, in: fullImageRect)
        context.restoreGState()

        return context.makeImage()
    }

    static func detectionRequestRegions(
        baseRegionOfInterest: CGRect?,
        imageWidth: Int,
        imageHeight: Int,
        configuration: ConferenceFaceBlurConfiguration = .production
    ) -> [CGRect] {
        let baseRegion = sanitizeRegionOfInterest(baseRegionOfInterest)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        var requestRegions = [baseRegion]

        guard shouldRunExtraROIPasses(
            baseRegionOfInterest: baseRegion,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            configuration: configuration
        ) else {
            return requestRegions
        }

        let overlappingQuadrants = localOverlappingGridRegions(
            rows: 2,
            columns: 2,
            overlapFraction: configuration.quadrantOverlapFraction
        )
        for localRegion in overlappingQuadrants {
            guard let projectedRegion = projectLocalRegion(
                localRegion,
                into: baseRegion
            ) else {
                continue
            }
            appendUniqueNormalizedRect(projectedRegion, to: &requestRegions)
        }

        if configuration.includeCenterSquare,
           let centerRegion = projectLocalRegion(
               configuration.centerSquareLocalROI,
               into: baseRegion
           ) {
            appendUniqueNormalizedRect(centerRegion, to: &requestRegions)
        }

        return requestRegions
    }

    static func remapDetectedRectFromRegionOfInterest(
        _ detectedRect: CGRect,
        regionOfInterest: CGRect
    ) -> CGRect? {
        _ = regionOfInterest
        // VNDetectFaceRectanglesRequest observations are already reported in the
        // processed image's normalized coordinate space. Applying the ROI again
        // double-scales and shifts boxes, which causes visible blur drift.
        return sanitizeRegionOfInterest(detectedRect)
    }

    static func mergedDetections(
        _ rects: [CGRect],
        overlapThreshold: CGFloat
    ) -> [CGRect] {
        let sanitizedRects = rects.compactMap(sanitizeRegionOfInterest)
        guard sanitizedRects.count > 1 else {
            return sanitizedRects
        }

        var mergedRects: [CGRect] = []
        for rect in sanitizedRects.sorted(by: { rectArea($0) > rectArea($1) }) {
            if let existingIndex = mergedRects.firstIndex(where: {
                overlapScore(between: rect, and: $0) >= overlapThreshold
            }) {
                let unionRect = mergedRects[existingIndex].union(rect)
                mergedRects[existingIndex] = sanitizeRegionOfInterest(unionRect) ?? mergedRects[existingIndex]
            } else {
                mergedRects.append(rect)
            }
        }

        return mergedRects
    }

    private func performDetectionPasses(
        in image: CGImage,
        requestRegionsOfInterest: [CGRect]
    ) throws -> [CGRect] {
        let requests = requestRegionsOfInterest.map { requestRegion in
            let request = VNDetectFaceRectanglesRequest()
            request.regionOfInterest = requestRegion
            return request
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(requests)

        return zip(requests, requestRegionsOfInterest).flatMap { request, requestRegion in
            (request.results ?? []).compactMap { observation in
                Self.remapDetectedRectFromRegionOfInterest(
                    observation.boundingBox,
                    regionOfInterest: requestRegion
                )
            }
        }
    }

    private func expandedFaceRects(
        from normalizedRects: [CGRect],
        image: CGImage
    ) -> [CGRect] {
        normalizedRects.compactMap { normalizedRect in
            pixelRect(
                from: normalizedRect,
                imageWidth: image.width,
                imageHeight: image.height
            )
        }.compactMap { rect in
            expandedRect(
                rect,
                maxWidth: CGFloat(image.width),
                maxHeight: CGFloat(image.height)
            )
        }
    }

    private func pixelRect(
        from normalizedRect: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0 else {
            return nil
        }

        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        let minX = max(0, normalizedRect.minX * width)
        let minY = max(0, normalizedRect.minY * height)
        let maxX = min(width, normalizedRect.maxX * width)
        let maxY = min(height, normalizedRect.maxY * height)
        let rect = CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        ).integral

        guard rect.width > 1, rect.height > 1 else {
            return nil
        }
        return rect
    }

    private func circularMaskRect(for rect: CGRect) -> CGRect {
        let diameter = max(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - (diameter / 2),
            y: rect.midY - (diameter / 2)
        )
        return CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)).integral
    }

    private func expandedRect(
        _ rect: CGRect,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGRect? {
        // Keep the blur mask larger than the raw face box so privacy stays fail-closed.
        let paddingX = max(12, rect.width * 0.75)
        let paddingY = max(12, rect.height * 0.75)
        let expanded = rect.insetBy(dx: -paddingX, dy: -paddingY)
        let bounded = expanded.intersection(
            CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight)
        ).integral

        guard bounded.width > 1, bounded.height > 1 else {
            return nil
        }
        return bounded
    }

    private func makeBlurredImage(
        from image: CGImage,
        faceRects: [CGRect]
    ) -> CGImage? {
        let inputImage = CIImage(cgImage: image)
        let maxFaceDimension = faceRects.reduce(CGFloat.zero) { partialResult, rect in
            max(partialResult, max(rect.width, rect.height))
        }
        let blurRadius = max(24, min(96, maxFaceDimension * 0.35))

        guard let gaussianBlur = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }

        gaussianBlur.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
        gaussianBlur.setValue(blurRadius, forKey: kCIInputRadiusKey)

        guard let blurredOutput = gaussianBlur.outputImage?.cropped(to: inputImage.extent) else {
            return nil
        }

        return ciContext.createCGImage(blurredOutput, from: inputImage.extent)
    }

    private static func detectionMode(
        baseRegionOfInterest: CGRect?,
        requestCount: Int
    ) -> ConferenceFaceBlurResult.DetectionMode {
        if requestCount > 1 {
            return baseRegionOfInterest == nil ? .multiPassFullFrame : .multiPassRegionOfInterest
        }
        return baseRegionOfInterest == nil ? .fullFrame : .regionOfInterest
    }

    private static func shouldRunExtraROIPasses(
        baseRegionOfInterest: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        configuration: ConferenceFaceBlurConfiguration
    ) -> Bool {
        switch configuration.extraROIPolicy {
        case .disabled:
            return false
        case .always:
            return true
        case .whenBaseRegionIsLarge:
            let baseWidth = baseRegionOfInterest.width * CGFloat(imageWidth)
            let baseHeight = baseRegionOfInterest.height * CGFloat(imageHeight)
            return min(baseWidth, baseHeight) >= configuration.minimumBaseRegionShortEdgePixels
        }
    }

    private static func localOverlappingGridRegions(
        rows: Int,
        columns: Int,
        overlapFraction: CGFloat
    ) -> [CGRect] {
        guard rows > 0, columns > 0 else {
            return []
        }

        return Array(0..<(rows * columns)).compactMap { index in
            let row = index / columns
            let column = index % columns
            let cellWidth = 1.0 / CGFloat(columns)
            let cellHeight = 1.0 / CGFloat(rows)
            let baseRect = CGRect(
                x: CGFloat(column) * cellWidth,
                y: CGFloat(rows - row - 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            let expandedRect = baseRect.insetBy(
                dx: -(cellWidth * overlapFraction),
                dy: -(cellHeight * overlapFraction)
            )
            return sanitizeRegionOfInterest(expandedRect)
        }
    }

    private static func projectLocalRegion(
        _ localRegion: CGRect,
        into baseRegion: CGRect
    ) -> CGRect? {
        guard let sanitizedLocalRegion = sanitizeRegionOfInterest(localRegion) else {
            return nil
        }
        let projectedRegion = CGRect(
            x: baseRegion.minX + (sanitizedLocalRegion.minX * baseRegion.width),
            y: baseRegion.minY + (sanitizedLocalRegion.minY * baseRegion.height),
            width: sanitizedLocalRegion.width * baseRegion.width,
            height: sanitizedLocalRegion.height * baseRegion.height
        )
        return sanitizeRegionOfInterest(projectedRegion)
    }

    private static func appendUniqueNormalizedRect(
        _ rect: CGRect,
        to rects: inout [CGRect]
    ) {
        guard let sanitizedRect = sanitizeRegionOfInterest(rect) else {
            return
        }
        let epsilon: CGFloat = 0.0005
        if rects.contains(where: {
            abs($0.minX - sanitizedRect.minX) <= epsilon &&
            abs($0.minY - sanitizedRect.minY) <= epsilon &&
            abs($0.width - sanitizedRect.width) <= epsilon &&
            abs($0.height - sanitizedRect.height) <= epsilon
        }) {
            return
        }
        rects.append(sanitizedRect)
    }

    private static func sanitizeRegionOfInterest(_ roi: CGRect?) -> CGRect? {
        guard let roi else { return nil }

        let clampedMinX = max(0, min(1, roi.minX))
        let clampedMinY = max(0, min(1, roi.minY))
        let clampedMaxX = max(clampedMinX, min(1, roi.maxX))
        let clampedMaxY = max(clampedMinY, min(1, roi.maxY))
        let clamped = CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: clampedMaxX - clampedMinX,
            height: clampedMaxY - clampedMinY
        )

        guard clamped.width > 0.001, clamped.height > 0.001 else {
            return nil
        }

        return clamped
    }

    private static func overlapScore(
        between lhs: CGRect,
        and rhs: CGRect
    ) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }

        let intersectionArea = rectArea(intersection)
        let unionArea = rectArea(lhs) + rectArea(rhs) - intersectionArea
        let smallerArea = min(rectArea(lhs), rectArea(rhs))
        guard unionArea > 0, smallerArea > 0 else {
            return 0
        }

        return max(intersectionArea / unionArea, intersectionArea / smallerArea)
    }

    private static func rectArea(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }
}
