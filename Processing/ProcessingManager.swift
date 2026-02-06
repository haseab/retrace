import Foundation
import Shared

/// Debug logger that writes to /tmp/retrace_debug.log
private func debugLog(_ message: String) {
    let logLine = "[\(Log.timestamp())] [ProcessingManager] \(message)\n"
    let logPath = "/tmp/retrace_debug.log"

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: logLine.data(using: .utf8))
    }
}

// MARK: - ProcessingManager

/// Main actor implementing ProcessingProtocol
/// Coordinates OCR, Accessibility API, and text merging
public actor ProcessingManager: ProcessingProtocol {

    // MARK: - Dependencies

    private let ocr: VisionOCR
    private let accessibility: AccessibilityService
    private let merger: TextMerger

    // MARK: - State

    private var config: ProcessingConfig

    // Processing queue
    private var processingQueue: [(CapturedFrame, (Result<ExtractedText, ProcessingError>) -> Void)] = []
    private var isProcessing = false

    // Region-based OCR state
    private var fullFrameCache: FullFrameOCRCache?
    private var previousFrame: CapturedFrame?
    private var useRegionBasedOCR: Bool = true

    // Serialization for region-based OCR (prevents concurrent cache access)
    private var extractionQueue: [CheckedContinuation<Void, Never>] = []
    private var isExtractingText: Bool = false

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

    /// Helper to resume next queued extraction or clear the flag
    private func finishExtraction() {
        debugLog("finishExtraction, queue size=\(extractionQueue.count)")
        if !extractionQueue.isEmpty {
            let next = extractionQueue.removeFirst()
            next.resume()
        } else {
            isExtractingText = false
        }
    }

    public func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        let startTime = Date()
        debugLog("extractText START frame=\(frame.width)x\(frame.height), isExtractingText=\(isExtractingText)")

        // Serialize extraction calls to prevent race conditions with region-based OCR cache
        if isExtractingText {
            debugLog("Waiting in queue...")
            await withCheckedContinuation { continuation in
                extractionQueue.append(continuation)
            }
            debugLog("Resumed from queue")
        }
        isExtractingText = true

        debugLog("extractText RUNNING frame=\(frame.width)x\(frame.height)")

        do {
            let result = try await extractTextInternal(from: frame, startTime: startTime)
            finishExtraction()
            return result
        } catch {
            finishExtraction()
            throw error
        }
    }

    private func extractTextInternal(from frame: CapturedFrame, startTime: Date) async throws -> ExtractedText {

        // Ensure full-frame cache is initialized for region-based OCR
        if fullFrameCache == nil {
            debugLog("Creating new FullFrameOCRCache")
            fullFrameCache = FullFrameOCRCache()
        }

        // Perform OCR (region-based or full-frame)
        let ocrRegions: [TextRegion]

        if useRegionBasedOCR, let cache = fullFrameCache {
            // Use region-based OCR for energy efficiency
            // Tiles are used for CHANGE DETECTION only, not for OCR bounding boxes
            debugLog("Starting region-based OCR, hasPreviousFrame=\(previousFrame != nil)")
            let result = try await ocr.recognizeTextRegionBased(
                frame: frame,
                previousFrame: previousFrame,
                cache: cache,
                config: config
            )
            ocrRegions = result.regions
            debugLog("Region OCR complete: \(result.stats.tilesOCRed)/\(result.stats.totalTiles) tiles, \(result.regions.count) regions")

            // Track energy savings
            regionOCRFrameCount += 1
            totalEnergySavings += result.stats.energySavings

            // Log significant energy savings
            if result.stats.energySavings > 0.1 {
                Log.debug("[ProcessingManager] Region OCR: \(result.stats.tilesOCRed)/\(result.stats.totalTiles) tiles, \(Int(result.stats.energySavings * 100))% energy saved, \(String(format: "%.1f", result.stats.totalTimeMs))ms", category: .processing)
            }
        } else {
            // Fallback to full-frame OCR
            debugLog("Starting full-frame OCR")
            ocrRegions = try await ocr.recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config
            )
            debugLog("Full-frame OCR complete: \(ocrRegions.count) regions")
        }

        // Store frame for next comparison (region-based OCR)
        previousFrame = frame

        // Separate UI chrome from main content
        // Chrome = top 5% (menu bar/status bar) + bottom 5% (dock)
        // Coordinates are now in pixel space with Y flipped (0 = top)
        let frameHeight = CGFloat(frame.height)
        let topChromeThreshold = frameHeight * 0.05    // Top 5%
        let bottomChromeThreshold = frameHeight * 0.95 // Bottom 5%

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
        var metadata = frame.metadata
        if let axResult = axResult {
            metadata = FrameMetadata(
                appBundleID: axResult.appInfo.bundleID,
                appName: axResult.appInfo.name,
                windowName: axResult.appInfo.windowName,
                browserURL: axResult.appInfo.browserURL ?? frame.metadata.browserURL,
                displayID: frame.metadata.displayID
            )
        }

        // Extract browser URL from OCR if not already available from Accessibility API
        // This handles browsers that don't expose URL via AX API (Firefox, Opera, Vivaldi, etc.)
        // Only searches chrome text (top 5% - address bar area)
        if metadata.browserURL == nil {
            if let extractedURL = URLExtractor.extractURL(chromeText: chromeText) {
                metadata = FrameMetadata(
                    appBundleID: metadata.appBundleID,
                    appName: metadata.appName,
                    windowName: metadata.windowName,
                    browserURL: extractedURL,
                    displayID: metadata.displayID
                )
            }
        }

        // Create ExtractedText with separated main/chrome regions
        // Note: CapturedFrame doesn't have an ID yet (assigned by database on insert)
        let extractedText = ExtractedText(
            frameID: FrameID(value: 0), // Placeholder - will be updated by caller after DB insert
            timestamp: frame.timestamp,
            regions: mainRegions,        // Main content regions (c0)
            chromeRegions: chromeRegions, // UI chrome regions (c1)
            fullText: fullText,          // Main content text
            chromeText: chromeText,      // UI chrome text
            metadata: metadata
        )

        // Update statistics
        let ocrTime = Date().timeIntervalSince(startTime) * 1000  // Convert to ms
        framesProcessed += 1
        totalOCRTimeMs += ocrTime
        totalTextLength += extractedText.wordCount

        debugLog("extractTextInternal COMPLETE")
        return extractedText
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

    // MARK: - Processing Queue

    public func queueFrame(
        _ frame: CapturedFrame,
        completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void
    ) async {
        processingQueue.append((frame, completion))

        // Start processing if not already running
        if !isProcessing {
            await processQueue()
        }
    }

    public var queuedFrameCount: Int {
        return processingQueue.count
    }

    public func waitForQueueDrain() async {
        while !processingQueue.isEmpty || isProcessing {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
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
    }

    // MARK: - Private Methods

    private func processQueue() async {
        isProcessing = true

        while !processingQueue.isEmpty {
            let (frame, completion) = processingQueue.removeFirst()

            do {
                let text = try await extractText(from: frame)
                completion(.success(text))
            } catch let error as ProcessingError {
                errorCount += 1
                Log.error("[ProcessingManager] Queue processing failed for frame: \(error)", category: .processing)
                completion(.failure(error))
            } catch {
                errorCount += 1
                Log.error("[ProcessingManager] Queue processing failed for frame: \(error.localizedDescription)", category: .processing, error: error)
                completion(.failure(.ocrFailed(underlying: error.localizedDescription)))
            }
        }

        isProcessing = false
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
