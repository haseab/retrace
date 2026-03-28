import Foundation
import Shared

private struct BuildExtractedTextOutput {
    let extractedText: ExtractedText
    let attributedResidualBytes: Int64
    let outputPayloadBytes: Int64
}

private enum OCRExtractionMode: Equatable {
    case fullFrame
    case regionBased
}

private struct OCRExtractionOutput {
    let regions: [TextRegion]
    let mode: OCRExtractionMode
}

// MARK: - ProcessingManager

/// Main actor implementing ProcessingProtocol
/// Coordinates OCR, Accessibility API, and text merging
public actor ProcessingManager: ProcessingProtocol {
    private static let memoryLedgerPreviousFrameTag = "processing.ocr.previousFrame"
    private static let memoryLedgerRegionCacheTag = "processing.ocr.fullFrameRegionCache"
    private static let memoryLedgerTileGridTag = "processing.ocr.fullFrameTileGrid"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30

    // MARK: - Dependencies

    private let ocr: VisionOCR
    private let accessibility: AccessibilityService
    private let merger: TextMerger

    // MARK: - State

    private var config: ProcessingConfig

    // Region-based OCR state
    private var fullFrameCache: FullFrameOCRCache?
    private var previousFrame: CapturedFrame?
    private var useRegionBasedOCR: Bool = true


    // Region OCR statistics
    private var totalEnergySavings: Double = 0
    private var regionOCRFrameCount = 0

    // Statistics
    private var framesProcessed = 0
    private var totalOCRTimeMs: Double = 0
    private var totalTextLength = 0
    private var errorCount = 0

    // MARK: - Initialization

    public init(config: ProcessingConfig = .default) {
        self.config = config
        self.ocr = VisionOCR(recognitionLanguages: config.recognitionLanguages)
        self.accessibility = AccessibilityService()
        self.merger = TextMerger()
    }

    // MARK: - ProcessingProtocol

    public func initialize(config: ProcessingConfig) async throws {
        self.config = config
    }


    public func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        let instrumentation = await ProcessingExtractRequestInstrumentation.begin()
        let startTime = Date()
        do {
            let ocrExtraction = try await extractOCRRegions(
                from: frame,
                instrumentation: instrumentation
            )
            let ocrRegions = ocrExtraction.regions
            let ocrStage = await instrumentation.recordOCRStage(
                ocrRegions: ocrRegions,
                schedulesReturnResidualProbes: ocrExtraction.mode == .fullFrame
            )

            let buildOutput = try await buildExtractedText(
                timestamp: frame.timestamp,
                frameHeight: frame.height,
                metadata: frame.metadata,
                ocrRegions: ocrRegions,
                startTime: startTime,
                instrumentation: instrumentation
            )
            await instrumentation.recordExtractCompletion(
                ocrStage: ocrStage,
                attributedResidualBytes: buildOutput.attributedResidualBytes,
                outputPayloadBytes: buildOutput.outputPayloadBytes
            )

            await instrumentation.finish()
            return buildOutput.extractedText
        } catch {
            await instrumentation.finish()
            throw error
        }
    }

    private func extractOCRRegions(
        from frame: CapturedFrame,
        instrumentation: ProcessingExtractRequestInstrumentation
    ) async throws -> OCRExtractionOutput {
        // Ensure full-frame cache is initialized for region-based OCR
        if fullFrameCache == nil {
            fullFrameCache = FullFrameOCRCache()
        }

        // Perform OCR (region-based or full-frame)
        let ocrOutput: OCRExtractionOutput

        if useRegionBasedOCR, let cache = fullFrameCache {
            // Use region-based OCR for energy efficiency
            // Tiles are used for CHANGE DETECTION only, not for OCR bounding boxes
            let result = try await ocr.recognizeTextRegionBased(
                frame: frame,
                previousFrame: previousFrame,
                cache: cache,
                config: config,
                extractInstrumentation: instrumentation
            )
            ocrOutput = OCRExtractionOutput(
                regions: result.regions,
                mode: .regionBased
            )

            // Track energy savings
            regionOCRFrameCount += 1
            totalEnergySavings += result.stats.energySavings

            // Log significant energy savings
            if result.stats.energySavings > 0.1 {
                Log.debug("[ProcessingManager] Region OCR: \(result.stats.tilesOCRed)/\(result.stats.totalTiles) tiles, \(Int(result.stats.energySavings * 100))% energy saved, \(String(format: "%.1f", result.stats.totalTimeMs))ms", category: .processing)
            }
        } else {
            // Fallback to full-frame OCR
            let regions = try await ocr.recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config,
                extractInstrumentation: instrumentation
            )
            ocrOutput = OCRExtractionOutput(
                regions: regions,
                mode: .fullFrame
            )
        }

        // Store frame for next comparison (region-based OCR)
        previousFrame = frame
        await updateMemoryLedger()
        return ocrOutput
    }

    private func buildExtractedText(
        timestamp: Date,
        frameHeight: Int,
        metadata frameMetadata: FrameMetadata,
        ocrRegions: [TextRegion],
        startTime: Date,
        instrumentation: ProcessingExtractRequestInstrumentation
    ) async throws -> BuildExtractedTextOutput {
        let buildStage = await instrumentation.beginBuildStage()

        // Separate UI chrome from main content
        // Chrome = top 5% (menu bar/status bar) + bottom 5% (dock)
        // Coordinates are now in pixel space with Y flipped (0 = top)
        let normalizedFrameHeight = max(CGFloat(frameHeight), 1)
        let topChromeThreshold = normalizedFrameHeight * 0.05    // Top 5%
        let bottomChromeThreshold = normalizedFrameHeight * 0.95 // Bottom 5%

        var mainRegions: [TextRegion] = []
        var chromeRegions: [TextRegion] = []

        for region in ocrRegions {
            let regionTopY = region.bounds.origin.y
            let regionBottomY = region.bounds.origin.y + region.bounds.height

            // Check if region is in UI chrome areas
            let isTopChrome = regionBottomY <= topChromeThreshold
            let isBottomChrome = regionTopY >= bottomChromeThreshold

            if isTopChrome || isBottomChrome {
                chromeRegions.append(region)
            } else {
                mainRegions.append(region)
            }
        }
        // Extract accessibility text (if enabled and permitted)
        var axResult: AccessibilityResult? = nil
        var axText: String? = nil
        if config.accessibilityEnabled {
            let hasPermission = await accessibility.hasPermission()
            if hasPermission {
                do {
                    axResult = try await accessibility.getFocusedAppText()
                    axText = axResult?.textElements.map(\.text).joined(separator: " ")
                } catch {
                    Log.debug("[ProcessingManager] Accessibility text extraction failed (non-critical): \(error.localizedDescription)", category: .processing)
                    axResult = nil
                }
            }
        }
        // Build OCR text from main regions only (chrome text stored separately)
        let ocrText = mainRegions.map(\.text).joined(separator: " ")
        let chromeText = chromeRegions.map(\.text).joined(separator: " ")

        // Merge OCR and accessibility text
        let fullText = merger.mergeText(ocrText: ocrText, accessibilityText: axText)

        // Merge accessibility metadata with existing metadata
        // Preserve browserURL from capture phase if accessibility doesn't provide one
        var metadata = frameMetadata
        if let axResult = axResult {
            metadata = FrameMetadata(
                appBundleID: axResult.appInfo.bundleID,
                appName: axResult.appInfo.name,
                windowName: axResult.appInfo.windowName,
                browserURL: axResult.appInfo.browserURL ?? frameMetadata.browserURL,
                redactionReason: frameMetadata.redactionReason,
                displayID: frameMetadata.displayID
            )
        }

        // Create ExtractedText with separated main/chrome regions
        // Note: CapturedFrame doesn't have an ID yet (assigned by database on insert)
        let extractedText = ExtractedText(
            frameID: FrameID(value: 0), // Placeholder - will be updated by caller after DB insert
            timestamp: timestamp,
            regions: mainRegions,        // Main content regions (c0)
            chromeRegions: chromeRegions, // UI chrome regions (c1)
            fullText: fullText,          // Main content text
            chromeText: chromeText,      // UI chrome text
            metadata: metadata
        )
        let outputPayloadBytes = buildStage.recordOutputPayload(extractedText)

        // Update statistics
        let ocrTime = Date().timeIntervalSince(startTime) * 1000  // Convert to ms
        framesProcessed += 1
        totalOCRTimeMs += ocrTime
        totalTextLength += extractedText.wordCount

        let buildResidualBytes = await buildStage.recordBuildResidual(
            outputPayloadBytes: outputPayloadBytes
        )

        return BuildExtractedTextOutput(
            extractedText: extractedText,
            attributedResidualBytes: buildResidualBytes,
            outputPayloadBytes: outputPayloadBytes
        )
    }

    public func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] {
        return try await ocr.recognizeText(
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            config: config
        )
    }

    public func extractTextViaAccessibility() async throws -> [TextRegion] {
        guard config.accessibilityEnabled else {
            return []
        }

        guard await accessibility.hasPermission() else {
            throw ProcessingError.accessibilityPermissionDenied
        }

        let result = try await accessibility.getFocusedAppText()

        // Convert accessibility text elements to TextRegions
        // Note: We use a dummy FrameID since AX text is not tied to a specific frame
        let dummyFrameID = FrameID(value: 0)
        return result.textElements.map { element in
            TextRegion(
                frameID: dummyFrameID,
                text: element.text,
                bounds: .zero,  // AX doesn't provide spatial info
                confidence: 1.0  // AX text is always accurate
            )
        }
    }

    // MARK: - Configuration

    public func updateConfig(_ config: ProcessingConfig) async {
        self.config = config
    }

    public func getConfig() async -> ProcessingConfig {
        return config
    }

    // MARK: - Statistics

    public func getStatistics() async -> ProcessingStatistics {
        return ProcessingStatistics(
            framesProcessed: framesProcessed,
            averageOCRTimeMs: framesProcessed > 0 ? totalOCRTimeMs / Double(framesProcessed) : 0,
            averageTextLength: framesProcessed > 0 ? totalTextLength / framesProcessed : 0,
            errorCount: errorCount
        )
    }

    /// Get region-based OCR statistics
    public func getRegionOCRStats() async -> (averageEnergySavings: Double, frameCount: Int, cacheStats: (hits: Int, misses: Int, size: Int, hitRate: Double)?) {
        let avgSavings = regionOCRFrameCount > 0 ? totalEnergySavings / Double(regionOCRFrameCount) : 0
        if let cache = fullFrameCache {
            let stats = await cache.getStats()
            return (avgSavings, regionOCRFrameCount, (stats.hits, stats.misses, stats.regionCount, stats.hitRate))
        }
        return (avgSavings, regionOCRFrameCount, nil)
    }

    // MARK: - Region-Based OCR Configuration

    /// Enable or disable region-based OCR
    /// When enabled, only changed regions are OCR'd for energy efficiency
    /// Tiles are used for change detection only - bounding boxes remain paragraph-level
    public func setRegionBasedOCR(enabled: Bool) {
        useRegionBasedOCR = enabled
        if !enabled {
            // Clear cache and previous frame when disabled
            Task {
                await fullFrameCache?.invalidateAll()
                await self.updateMemoryLedger()
            }
            previousFrame = nil
        }
    }

    /// Check if region-based OCR is enabled
    public func isRegionBasedOCREnabled() -> Bool {
        return useRegionBasedOCR
    }

    /// Invalidate the OCR cache (useful when significant UI changes occur)
    public func invalidateTileCache() async {
        await fullFrameCache?.invalidateAll()
        previousFrame = nil
        await updateMemoryLedger()
    }

    private func updateMemoryLedger() async {
        let previousFrameBytes = Int64(previousFrame?.imageData.count ?? 0)
        let cacheEstimate = await fullFrameCache?.memoryEstimate()

        MemoryLedger.set(
            tag: Self.memoryLedgerPreviousFrameTag,
            bytes: previousFrameBytes,
            count: previousFrame == nil ? 0 : 1,
            unit: "frames",
            function: "processing.ocr",
            kind: "previous-frame",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerRegionCacheTag,
            bytes: cacheEstimate?.regionBytes ?? 0,
            count: cacheEstimate?.regionCount ?? 0,
            unit: "regions",
            function: "processing.ocr",
            kind: "region-cache",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerTileGridTag,
            bytes: cacheEstimate?.tileGridBytes ?? 0,
            count: cacheEstimate?.tileCount ?? 0,
            unit: "tiles",
            function: "processing.ocr",
            kind: "tile-grid-cache",
            note: "estimated"
        )
        MemoryLedger.emitSummary(
            reason: "processing.ocr.functional_memory",
            category: .processing,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }
}

// MARK: - Accessibility Helpers

extension ProcessingManager {

    /// Check if Accessibility permission is granted
    public func hasAccessibilityPermission() async -> Bool {
        return await accessibility.hasPermission()
    }

    /// Request Accessibility permission (opens System Settings)
    public func requestAccessibilityPermission() async {
        await accessibility.requestPermission()
    }

    /// Get information about the frontmost application
    public func getFrontmostAppInfo() async throws -> AppInfo {
        return try await accessibility.getFrontmostAppInfo()
    }
}
