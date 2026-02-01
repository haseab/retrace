import Foundation
import Shared

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

    // Statistics
    private var framesProcessed = 0
    private var totalOCRTimeMs: Double = 0
    private var totalTextLength = 0
    private var errorCount = 0

    // MARK: - Initialization

    public init(config: ProcessingConfig = .default) {
        self.config = config
        self.ocr = VisionOCR()
        self.accessibility = AccessibilityService()
        self.merger = TextMerger()
    }

    // MARK: - ProcessingProtocol

    public func initialize(config: ProcessingConfig) async throws {
        self.config = config
    }

    public func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        let startTime = Date()

        // Perform OCR
        let ocrRegions = try await ocr.recognizeText(
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            config: config
        )

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
