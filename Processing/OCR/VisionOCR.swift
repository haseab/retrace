import Foundation
import Vision
import CoreGraphics
import Shared

// MARK: - VisionOCR

/// Vision framework implementation of OCRProtocol
public final class VisionOCR: OCRProtocol, @unchecked Sendable {
    /// Recognition languages for OCR
    private let recognitionLanguages: [String]

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
        try await recognizeText(
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            config: config,
            extractInstrumentation: nil
        )
    }

    func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig,
        extractInstrumentation: ProcessingExtractRequestInstrumentation?
    ) async throws -> [TextRegion] {
        let requestConfig = Self.fullFrameRecognitionRequestConfig()
        if let extractInstrumentation {
            await extractInstrumentation.prepareForOCR(reason: requestConfig.memoryReason)
        } else {
            await ProcessingExtractMemoryLedger.reconcileHandoffObservedResidualToCurrentFootprint(
                reason: requestConfig.memoryReason
            )
        }
        Self.resetRequestScopedTags(Self.fullFrameResetSpecs)
        let fullFrameBaselineSnapshot = await Self.synchronizedLedgerSnapshot()
        let fullFrameRecognition = try await recognizeTextWithEnvelope(
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            config: config,
            requestConfig: requestConfig
        )
        let postFullFrameSnapshot = await Self.synchronizedLedgerSnapshot()
        let fullFramePayloadBytes = Self.estimatedTextRegionBufferBytes(fullFrameRecognition.regions)
        let blindResidualClaimBytes = max(0, fullFrameRecognition.blindResidualClaim?.bytes ?? 0)
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.fullFrameOCRResultRetention",
            function: "processing.ocr.full_frame",
            reason: "processing.ocr.vision_full_frame",
            bytes: fullFramePayloadBytes,
            kind: "full-frame-ocr-results",
            note: "estimated-results-payload",
            delay: 4,
            forceSummary: true
        )
        let fullFrameOCRCallResidualBytes = max(
            0,
            Self.measuredLedgerResidualBytes(
                before: fullFrameBaselineSnapshot,
                after: postFullFrameSnapshot,
                subtractingBytes: fullFramePayloadBytes
            ) - blindResidualClaimBytes
        )
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.fullFrameOCRCallResidual",
            function: "processing.ocr.full_frame",
            reason: "processing.ocr.vision_full_frame",
            bytes: fullFrameOCRCallResidualBytes,
            kind: "full-frame-ocr-call-residual",
            note: "observed-minus-results-payload-net-blind-residual",
            delay: 4,
            forceSummary: true
        )
        if let extractInstrumentation {
            await extractInstrumentation.finalizeFullFrameResiduals(
                reason: requestConfig.memoryReason,
                blindResidualClaimBytes: blindResidualClaimBytes,
                callResidualBytes: fullFrameOCRCallResidualBytes
            )
        } else {
            await ProcessingExtractRequestInstrumentation.reconcileFullFrameResiduals(
                reason: requestConfig.memoryReason,
                blindResidualClaimBytes: blindResidualClaimBytes,
                callResidualBytes: fullFrameOCRCallResidualBytes
            )
            Self.handoffCurrentFullFrameBlindResidualToExtract(reason: requestConfig.memoryReason)
            ProcessingExtractRequestInstrumentation.scheduleFullFrameBlindResidualClear(reason: requestConfig.memoryReason)
        }
        return fullFrameRecognition.regions
    }

    // MARK: - Live Screenshot OCR

    /// Perform OCR directly on a CGImage (for live screenshot use case)
    /// Uses the same .accurate pipeline as frame processing
    /// Returns TextRegions with **normalized coordinates** (0.0-1.0) for direct use with OCRNodeWithText
    public func recognizeTextFromCGImage(_ cgImage: CGImage) async throws -> [TextRegion] {
        return try autoreleasepool {
            let memoryLease = VisionOCRMemoryLedger.begin(
                tag: "processing.ocr.liveScreenshotVisionRequest",
                function: "ui.live_screenshot_ocr",
                reason: "ui.live_screenshot_ocr",
                width: cgImage.width,
                height: cgImage.height,
                privateHeapTag: "processing.ocr.liveScreenshotPrivateHeap",
                privateHeapFunction: "ui.live_screenshot_ocr"
            )
            defer {
                VisionOCRMemoryLedger.end(lease: memoryLease, reason: "ui.live_screenshot_ocr")
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.recognitionLanguages = recognitionLanguages
            textRequest.usesLanguageCorrection = true

            do {
                try handler.perform([textRequest])
            } catch {
                throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
            }

            guard let observations = textRequest.results else {
                return []
            }

            return observations.compactMap { observation -> TextRegion? in
                guard observation.confidence >= 0.5 else { return nil }
                guard let topCandidate = observation.topCandidates(1).first else { return nil }
                let text = topCandidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                let box = observation.boundingBox
                let flippedY = 1.0 - box.origin.y - box.height
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
        }
    }

    // MARK: - Image Processing

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
        try await recognizeTextRegionBased(
            frame: frame,
            previousFrame: previousFrame,
            cache: cache,
            config: config,
            extractInstrumentation: nil
        )
    }

    func recognizeTextRegionBased(
        frame: CapturedFrame,
        previousFrame: CapturedFrame?,
        cache: FullFrameOCRCache,
        config: ProcessingConfig,
        extractInstrumentation: ProcessingExtractRequestInstrumentation?
    ) async throws -> RegionOCRResult {
        let totalStartTime = Date()
        let regionReason = "processing.ocr.vision_region"
        if let extractInstrumentation {
            await extractInstrumentation.prepareForOCR(reason: regionReason)
        } else {
            await ProcessingExtractMemoryLedger.reconcileHandoffObservedResidualToCurrentFootprint(
                reason: regionReason
            )
        }
        Self.resetRequestScopedTags(Self.regionResetSpecs)

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
                config: config,
                extractInstrumentation: extractInstrumentation
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

        let regionResidualEpoch = await MemoryLedger.beginResidualEpoch(
            ownerFunction: "processing.ocr.region_reocr",
            candidateConcurrentFunctions: ["capture.screen_capture"]
        )
        defer {
            Task(priority: .utility) {
                await MemoryLedger.endResidualEpoch(regionResidualEpoch)
            }
        }
        let changeDetectionBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

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
                config: config,
                extractInstrumentation: extractInstrumentation
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

        let postChangeDetectionSnapshot = await Self.synchronizedLedgerSnapshot()
        Self.publishPhaseResidual(
            tag: "processing.ocr.regionChangeDetection",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            kind: "region-change-detection",
            note: "observed-plus-buffer",
            before: changeDetectionBaselineSnapshot,
            after: postChangeDetectionSnapshot,
            structuralBytes: Self.estimatedTileBufferBytes(changeResult.changedTiles) +
                Self.estimatedTileBufferBytes(changeResult.unchangedTiles)
        )
        let partitionBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

        // Find which cached regions are affected by the changed tiles.
        let (affectedRegions, unaffectedRegions) = await cache.findAffectedRegions(changedTiles: changeResult.changedTiles)
        let postPartitionSnapshot = await Self.synchronizedLedgerSnapshot()
        Self.publishPhaseResidual(
            tag: "processing.ocr.regionCachePartition",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            kind: "region-cache-partition",
            note: "observed-plus-buffer",
            before: partitionBaselineSnapshot,
            after: postPartitionSnapshot,
            structuralBytes: Self.estimatedTextRegionBufferBytes(affectedRegions) +
                Self.estimatedTextRegionBufferBytes(unaffectedRegions)
        )
        let expansionBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

        // Expand OCR coverage to whole tiles touched by affected regions.
        // This avoids a boundary case where a region intersects changed tiles by only a few pixels.
        let reOCRTtiles = expandReOCRTiles(
            changedTiles: changeResult.changedTiles,
            affectedRegions: affectedRegions,
            frameWidth: frame.width,
            frameHeight: frame.height,
            changeDetector: changeDetector
        )
        let reOCRBounds = calculateBoundingBox(for: reOCRTtiles)
        let postExpansionSnapshot = await Self.synchronizedLedgerSnapshot()
        Self.publishPhaseResidual(
            tag: "processing.ocr.regionTileExpansion",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            kind: "region-tile-expansion",
            note: "observed-plus-buffer",
            before: expansionBaselineSnapshot,
            after: postExpansionSnapshot,
            structuralBytes: Self.estimatedTileBufferBytes(reOCRTtiles)
        )
        let regionOCRBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

        // Perform OCR only on the affected region using regionOfInterest
        let ocrStartTime = Date()
        let regionRecognition = try await recognizeTextInRegion(
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            region: reOCRBounds,
            config: config,
            extractInstrumentation: extractInstrumentation
        )
        let newRegions = regionRecognition.regions
        let ocrTime = Date().timeIntervalSince(ocrStartTime) * 1000
        let postRegionOCRSnapshot = await Self.synchronizedLedgerSnapshot()
        let newRegionsPayloadBytes = Self.estimatedTextRegionBufferBytes(newRegions)
        let blindResidualClaimBytes = max(0, regionRecognition.blindResidualClaim?.bytes ?? 0)
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.regionOCRResultRetention",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            bytes: newRegionsPayloadBytes,
            kind: "region-ocr-results",
            note: "estimated-results-payload",
            delay: 4,
            forceSummary: true
        )
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.regionOCRCallResidual",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            bytes: max(
                0,
                Self.measuredLedgerResidualBytes(
                    before: regionOCRBaselineSnapshot,
                    after: postRegionOCRSnapshot,
                    subtractingBytes: newRegionsPayloadBytes
                ) - blindResidualClaimBytes
            ),
            kind: "region-ocr-call-residual",
            note: "observed-minus-results-payload-net-blind-residual",
            delay: 4,
            forceSummary: true
        )
        let mergeBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

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
        let postMergeSnapshot = await Self.synchronizedLedgerSnapshot()
        Self.publishPhaseResidual(
            tag: "processing.ocr.regionMergeScratch",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            kind: "region-merge-scratch",
            note: "observed-plus-buffer",
            before: mergeBaselineSnapshot,
            after: postMergeSnapshot,
            structuralBytes: Self.estimatedTextRegionBufferBytes(filteredNewRegions) +
                Self.estimatedTextRegionBufferBytes(mergedRegions)
        )
        let cacheRefreshBaselineSnapshot = await Self.synchronizedLedgerSnapshot()

        // Update cache with merged results
        let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
        await cache.setFullFrameResults(regions: mergedRegions, tileGrid: allTiles)
        let postCacheRefreshSnapshot = await Self.synchronizedLedgerSnapshot()
        Self.publishPhaseResidual(
            tag: "processing.ocr.regionCacheRefresh",
            function: "processing.ocr.region_reocr",
            reason: regionReason,
            kind: "region-cache-refresh",
            note: "observed-plus-buffer",
            before: cacheRefreshBaselineSnapshot,
            after: postCacheRefreshSnapshot,
            structuralBytes: Self.estimatedTileBufferBytes(allTiles)
        )
        let postRegionReturnSnapshot = await Self.synchronizedLedgerSnapshot()
        let regionReturnResidualRequestBytes = Self.netNewUnattributedBytes(
            baselineSnapshot: changeDetectionBaselineSnapshot,
            currentSnapshot: postRegionReturnSnapshot
        )
        await MemoryLedger.flushPendingUpdates()
        let regionReturnResidualClaim = await MemoryLedger.claimCurrentUnattributed(
            epoch: regionResidualEpoch,
            requestedBytes: regionReturnResidualRequestBytes
        )
        let regionCallResidualBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: "processing.ocr.regionOCRCallResidual")
        if let extractInstrumentation {
            await extractInstrumentation.finalizeRegionResiduals(
                reason: regionReason,
                blindResidualBytes: blindResidualClaimBytes,
                regionReturnResidualClaim: regionReturnResidualClaim,
                callResidualBytes: regionCallResidualBytes,
                requestBaselineSnapshot: regionOCRBaselineSnapshot,
                requestPayloadBytes: newRegionsPayloadBytes,
                cacheBaselineSnapshot: cacheRefreshBaselineSnapshot
            )
        } else {
            Self.handoffRegionBlindResidualToExtract(
                reason: regionReason,
                blindResidualBytes: blindResidualClaimBytes,
                subtractingReturnResidualBytes: max(0, regionReturnResidualClaim.bytes)
            )
            switch regionReturnResidualClaim.target {
            case .owner:
                ProcessingExtractMemoryLedger.absorbRegionReturnResidualBytesIntoHandoff(
                    reason: regionReason,
                    regionReturnResidualBytes: max(0, regionReturnResidualClaim.bytes)
                )
                Self.clearRegionReturnResidualForHandoff(reason: regionReason)
            case .concurrent:
                Self.publishArbitedResidualClaim(
                    claim: regionReturnResidualClaim,
                    ownerTag: "processing.ocr.regionReturnResidual",
                    ownerFunction: "processing.ocr.region_reocr",
                    ownerKind: "region-return-residual",
                    ownerNote: "epoch-arbited-current-unattributed-after-cache-refresh",
                    delay: Self.blindResidualHoldSeconds,
                    reason: regionReason
                )
            case .none:
                break
            }
            await ProcessingExtractRequestInstrumentation.reconcileRegionResiduals(
                reason: regionReason,
                blindResidualClaimBytes: blindResidualClaimBytes,
                returnResidualClaimBytes: max(0, regionReturnResidualClaim.bytes),
                callResidualBytes: regionCallResidualBytes
            )
            ProcessingExtractRequestInstrumentation.scheduleRegionSettledReconciliation(
                reason: regionReason,
                blindResidualClaimBytes: blindResidualClaimBytes,
                returnResidualClaimBytes: max(0, regionReturnResidualClaim.bytes),
                callResidualBytes: regionCallResidualBytes
            )
            ProcessingExtractRequestInstrumentation.scheduleRegionTailResiduals(
                reason: regionReason,
                requestBaselineSnapshot: regionOCRBaselineSnapshot,
                requestPayloadBytes: newRegionsPayloadBytes,
                cacheBaselineSnapshot: cacheRefreshBaselineSnapshot
            )
        }
        let tilesOCRed = min(changeResult.totalTiles, reOCRTtiles.count)
        let tilesCached = max(0, changeResult.totalTiles - tilesOCRed)

        return RegionOCRResult(
            regions: mergedRegions,
            stats: RegionOCRStats(
                tilesOCRed: tilesOCRed,
                tilesCached: tilesCached,
                totalTiles: changeResult.totalTiles,
                changeDetectionTimeMs: changeResult.detectionTimeMs,
                ocrTimeMs: ocrTime,
                mergeTimeMs: mergeTime
            )
        )
    }

    /// Perform OCR on a specific region of the frame using regionOfInterest
    /// Returns TextRegions with bounds in full frame coordinates
    private func recognizeTextInRegion(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        region: CGRect,
        config: ProcessingConfig,
        extractInstrumentation: ProcessingExtractRequestInstrumentation?
    ) async throws -> EnvelopeRecognitionOutput {
        // If region covers the full frame, use standard OCR
        if region.minX <= 0 && region.minY <= 0 &&
           region.maxX >= CGFloat(width) && region.maxY >= CGFloat(height) {
            return EnvelopeRecognitionOutput(
                regions: try await recognizeText(
                    imageData: imageData,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    config: config,
                    extractInstrumentation: extractInstrumentation
                ),
                blindResidualClaim: nil
            )
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
        let requestConfig = Self.regionRecognitionRequestConfig(
            regionOfInterest: normalizedRegion,
            usesLanguageCorrection: config.ocrAccuracyLevel == .accurate
        )

        return try await recognizeTextWithEnvelope(
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            config: config,
            requestConfig: requestConfig
        )
    }

    private func recognizeTextWithEnvelope(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig,
        requestConfig: RecognitionRequestConfig
    ) async throws -> EnvelopeRecognitionOutput {
        let residualEpoch = await MemoryLedger.beginResidualEpoch(
            ownerFunction: requestConfig.memoryFunction,
            candidateConcurrentFunctions: ["capture.screen_capture"]
        )

        do {
            let envelopeBaselineSnapshot = await Self.synchronizedLedgerSnapshot()
            guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
                throw ProcessingError.imageConversionFailed
            }

            let postImageBridgeSnapshot = await Self.synchronizedLedgerSnapshot()
            let imageBridgeBytes = Self.measuredLedgerResidualBytes(
                before: envelopeBaselineSnapshot,
                after: postImageBridgeSnapshot
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.envelopeImageBridgeTag,
                function: requestConfig.envelopeImageBridgeFunction,
                reason: requestConfig.memoryReason,
                bytes: imageBridgeBytes,
                kind: "cgimage-bridge",
                note: "observed-footprint-delta",
                delay: requestConfig.phaseResidualDuration
            )

            let recognitionOutput = try performRecognition(
                on: cgImage,
                outputWidth: width,
                outputHeight: height,
                config: config,
                requestConfig: requestConfig
            )

            let postEnvelopeSnapshot = await Self.synchronizedLedgerSnapshot()
            let blindResidualRequestBytes = Self.netNewUnattributedBytes(
                baselineSnapshot: envelopeBaselineSnapshot,
                currentSnapshot: postEnvelopeSnapshot
            )
            await MemoryLedger.flushPendingUpdates()
            let blindResidualClaim = await MemoryLedger.claimCurrentUnattributed(
                epoch: residualEpoch,
                requestedBytes: blindResidualRequestBytes
            )
            Self.publishBlindResidualClaim(
                claim: blindResidualClaim,
                ownerTag: requestConfig.envelopeResidualTag,
                ownerFunction: requestConfig.envelopeResidualFunction,
                reason: requestConfig.memoryReason
            )

            await MemoryLedger.endResidualEpoch(residualEpoch)
            return EnvelopeRecognitionOutput(
                regions: recognitionOutput.regions,
                blindResidualClaim: blindResidualClaim.bytes > 0 ? blindResidualClaim : nil
            )
        } catch {
            await MemoryLedger.endResidualEpoch(residualEpoch)
            throw error
        }
    }

    private func performRecognition(
        on image: CGImage,
        outputWidth: Int,
        outputHeight: Int,
        config: ProcessingConfig,
        requestConfig: RecognitionRequestConfig
    ) throws -> VisionRecognitionOutput {
        try autoreleasepool {
            var retainedAdjustmentBytes: Int64 = 0
            var retainedMeasurementOverride: (bytes: Int64, note: String)?
            let memoryLease = VisionOCRMemoryLedger.begin(
                tag: requestConfig.memoryTag,
                function: requestConfig.memoryFunction,
                reason: requestConfig.memoryReason,
                width: outputWidth,
                height: outputHeight,
                privateHeapTag: requestConfig.privateHeapTag,
                privateHeapFunction: requestConfig.privateHeapFunction,
                retainedHeapTag: requestConfig.retainedHeapTag,
                retainedHeapFunction: requestConfig.retainedHeapFunction,
                retainedHeapDuration: requestConfig.retainedHeapDuration
            )
            defer {
                VisionOCRMemoryLedger.end(
                    lease: memoryLease,
                    reason: requestConfig.memoryReason,
                    retainedAdjustmentBytes: retainedAdjustmentBytes,
                    retainedMeasurementOverride: retainedMeasurementOverride
                )
            }

            let setupBaselineFootprintBytes = VisionOCRMemoryLedger.currentFootprintBytes()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = Self.recognitionLevel(for: config)
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = requestConfig.usesLanguageCorrection
            request.preferBackgroundProcessing = config.preferBackgroundProcessing
            request.regionOfInterest = requestConfig.regionOfInterest ?? CGRect(x: 0, y: 0, width: 1, height: 1)

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let postSetupFootprintBytes = VisionOCRMemoryLedger.currentFootprintBytes()
            let setupResidualBytes = VisionOCRMemoryLedger.measuredPhaseResidualBytes(
                baselineFootprintBytes: setupBaselineFootprintBytes ?? memoryLease?.baselineFootprintBytes,
                currentFootprintBytes: postSetupFootprintBytes
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.setupResidualTag,
                function: requestConfig.setupResidualFunction,
                reason: requestConfig.memoryReason,
                bytes: setupResidualBytes,
                kind: "vision-request-setup",
                note: "observed-footprint-delta",
                delay: requestConfig.phaseResidualDuration
            )

            let performBaselineFootprintBytes = postSetupFootprintBytes

            do {
                try handler.perform([request])
            } catch {
                throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
            }

            let postPerformFootprintBytes = VisionOCRMemoryLedger.currentFootprintBytes()
            let observations = request.results ?? []
            let postObservationBridgeFootprintBytes = VisionOCRMemoryLedger.currentFootprintBytes()
            let observationBridgeBytes = VisionOCRMemoryLedger.measuredPhaseResidualBytes(
                baselineFootprintBytes: postPerformFootprintBytes,
                currentFootprintBytes: postObservationBridgeFootprintBytes
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.observationBridgeTag,
                function: requestConfig.observationBridgeFunction,
                reason: requestConfig.memoryReason,
                bytes: observationBridgeBytes,
                kind: "vision-observation-bridge",
                note: "observed-footprint-delta",
                delay: requestConfig.phaseResidualDuration
            )
            let runtimeResidualBytes = VisionOCRMemoryLedger.measuredPhaseResidualBytes(
                baselineFootprintBytes: performBaselineFootprintBytes ?? memoryLease?.baselineFootprintBytes,
                currentFootprintBytes: postPerformFootprintBytes,
                subtractingBytes: (memoryLease?.requestBytes ?? 0) + (memoryLease?.privateHeapBytes ?? 0)
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.runtimeResidualTag,
                function: requestConfig.runtimeResidualFunction,
                reason: requestConfig.memoryReason,
                bytes: runtimeResidualBytes,
                kind: "vision-runtime-residual",
                note: "observed-footprint-delta",
                delay: requestConfig.phaseResidualDuration
            )

            var regions: [TextRegion] = []
            regions.reserveCapacity(observations.count)
            var retainedUTF16Units = 0
            var retainedObservationCount = 0

            for observation in observations {
                guard observation.confidence >= config.minimumConfidence else { continue }
                guard let topCandidate = observation.topCandidates(1).first else { continue }
                let text = topCandidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                retainedObservationCount += 1
                retainedUTF16Units += text.utf16.count

                let roiBox = observation.boundingBox

                let fullImageX: CGFloat
                let fullImageY: CGFloat
                let fullImageWidth: CGFloat
                let fullImageHeight: CGFloat

                if let regionOfInterest = requestConfig.regionOfInterest {
                    fullImageX = regionOfInterest.origin.x + (roiBox.origin.x * regionOfInterest.width)
                    fullImageY = regionOfInterest.origin.y + (roiBox.origin.y * regionOfInterest.height)
                    fullImageWidth = roiBox.width * regionOfInterest.width
                    fullImageHeight = roiBox.height * regionOfInterest.height
                } else {
                    fullImageX = roiBox.origin.x
                    fullImageY = roiBox.origin.y
                    fullImageWidth = roiBox.width
                    fullImageHeight = roiBox.height
                }

                let flippedY = 1.0 - fullImageY - fullImageHeight
                let pixelBounds = CGRect(
                    x: fullImageX * CGFloat(outputWidth),
                    y: flippedY * CGFloat(outputHeight),
                    width: fullImageWidth * CGFloat(outputWidth),
                    height: fullImageHeight * CGFloat(outputHeight)
                )

                regions.append(TextRegion(
                    frameID: FrameID(value: 0),
                    text: text,
                    bounds: pixelBounds,
                    confidence: Double(observation.confidence)
                ))
            }

            let resultsGraphBytes = VisionOCRMemoryLedger.estimatedResultsGraphBytes(
                observationCount: retainedObservationCount,
                retainedUTF16Units: retainedUTF16Units,
                regionCount: regions.count
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.resultsGraphTag,
                function: requestConfig.resultsGraphFunction,
                reason: requestConfig.memoryReason,
                bytes: resultsGraphBytes,
                kind: "ocr-results-graph",
                note: "estimated-results",
                delay: requestConfig.phaseResidualDuration
            )

            let postMaterializationFootprintBytes = VisionOCRMemoryLedger.currentFootprintBytes()
            let materializationResidualBytes = VisionOCRMemoryLedger.measuredPhaseResidualBytes(
                baselineFootprintBytes: postObservationBridgeFootprintBytes ?? postPerformFootprintBytes,
                currentFootprintBytes: postMaterializationFootprintBytes,
                subtractingBytes: resultsGraphBytes
            )
            VisionOCRMemoryLedger.setObservedResidual(
                tag: requestConfig.materializationResidualTag,
                function: requestConfig.materializationResidualFunction,
                reason: requestConfig.memoryReason,
                bytes: materializationResidualBytes,
                kind: "ocr-materialization-residual",
                note: "observed-footprint-delta",
                delay: requestConfig.phaseResidualDuration
            )
            retainedAdjustmentBytes =
                setupResidualBytes +
                runtimeResidualBytes +
                observationBridgeBytes +
                resultsGraphBytes +
                materializationResidualBytes

            retainedMeasurementOverride = VisionOCRMemoryLedger.retainedMeasurement(
                lease: memoryLease,
                subtractingBytes: retainedAdjustmentBytes
            )

            let totalAttributedBytes =
                (memoryLease?.requestBytes ?? 0) +
                (memoryLease?.privateHeapBytes ?? 0) +
                setupResidualBytes +
                runtimeResidualBytes +
                observationBridgeBytes +
                resultsGraphBytes +
                materializationResidualBytes +
                (retainedMeasurementOverride?.bytes ?? 0)

            return VisionRecognitionOutput(
                regions: regions,
                attributedBytes: totalAttributedBytes
            )
        }
    }
}
