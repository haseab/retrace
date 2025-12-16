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

        // Extract accessibility text (if enabled and permitted)
        var axResult: AccessibilityResult? = nil
        var axText: String? = nil
        if config.accessibilityEnabled {
            let hasPermission = await accessibility.hasPermission()
            if hasPermission {
                axResult = try? await accessibility.getFocusedAppText()
                axText = axResult?.textElements.map(\.text).joined(separator: " ")
            }
        }

        // Build OCR text
        let ocrText = ocrRegions.map(\.text).joined(separator: " ")

        // Merge OCR and accessibility text
        let fullText = merger.mergeText(ocrText: ocrText, accessibilityText: axText)

        // Merge accessibility metadata with existing metadata
        // Preserve browserURL from capture phase if accessibility doesn't provide one
        var metadata = frame.metadata
        if let axResult = axResult {
            metadata = FrameMetadata(
                appBundleID: axResult.appInfo.bundleID,
                appName: axResult.appInfo.name,
                windowTitle: axResult.appInfo.windowTitle,
                browserURL: axResult.appInfo.browserURL ?? frame.metadata.browserURL,
                displayID: frame.metadata.displayID
            )
        }

        // Create ExtractedText
        let extractedText = ExtractedText(
            frameID: frame.id,
            timestamp: frame.timestamp,
            regions: ocrRegions,  // Use OCR regions with their spatial data
            fullText: fullText,    // Merged text from both sources
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
        let dummyFrameID = FrameID()
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
                completion(.failure(error))
            } catch {
                errorCount += 1
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
