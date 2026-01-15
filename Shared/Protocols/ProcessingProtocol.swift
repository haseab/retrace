import Foundation

// MARK: - Processing Protocol

/// Text extraction from frames (OCR + Accessibility)
/// Owner: PROCESSING agent
public protocol ProcessingProtocol: Actor {

    // MARK: - Lifecycle

    /// Initialize processing with configuration
    func initialize(config: ProcessingConfig) async throws

    // MARK: - Text Extraction

    /// Extract text from a captured frame
    /// Combines OCR and Accessibility API results
    func extractText(from frame: CapturedFrame) async throws -> ExtractedText

    /// Extract text using only OCR
    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion]

    /// Extract text using only Accessibility API
    func extractTextViaAccessibility() async throws -> [TextRegion]

    // MARK: - Processing Queue

    /// Queue a frame for background processing
    /// Returns immediately, text will be sent to the provided handler
    func queueFrame(
        _ frame: CapturedFrame,
        completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void
    ) async

    /// Get number of frames in processing queue
    var queuedFrameCount: Int { get }

    /// Wait for all queued frames to be processed
    func waitForQueueDrain() async

    // MARK: - Configuration

    /// Update processing configuration
    func updateConfig(_ config: ProcessingConfig) async

    /// Get current configuration
    func getConfig() async -> ProcessingConfig
}

// MARK: - OCR Protocol

/// Optical Character Recognition operations
/// Owner: PROCESSING agent
public protocol OCRProtocol: Sendable {

    /// Perform OCR on image data
    /// - Parameters:
    ///   - imageData: Raw image bytes
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - bytesPerRow: Number of bytes per row (may include padding for alignment)
    ///   - config: Processing configuration
    /// - Returns: Array of recognized text regions
    func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig
    ) async throws -> [TextRegion]
}

// MARK: - Accessibility Protocol

/// Accessibility API text extraction
/// Owner: PROCESSING agent
public protocol AccessibilityProtocol: Actor {

    /// Check if accessibility permission is granted
    func hasPermission() -> Bool

    /// Request accessibility permission (opens System Settings)
    func requestPermission()

    /// Get text from the currently focused application
    func getFocusedAppText() async throws -> AccessibilityResult

    /// Get text from a specific application by bundle ID
    func getAppText(bundleID: String) async throws -> AccessibilityResult

    /// Get information about the frontmost application
    func getFrontmostAppInfo() async throws -> AppInfo
}

// MARK: - Supporting Types

/// Result from Accessibility API extraction
public struct AccessibilityResult: Sendable {
    public let appInfo: AppInfo
    public let textElements: [AccessibilityTextElement]
    public let extractionTime: Date

    public init(
        appInfo: AppInfo,
        textElements: [AccessibilityTextElement],
        extractionTime: Date = Date()
    ) {
        self.appInfo = appInfo
        self.textElements = textElements
        self.extractionTime = extractionTime
    }

    public var allText: String {
        textElements.map(\.text).joined(separator: " ")
    }
}

/// A text element from Accessibility API
public struct AccessibilityTextElement: Sendable {
    public let text: String
    public let role: String?         // e.g., "AXStaticText", "AXTextField"
    public let label: String?        // Accessibility label
    public let isEditable: Bool

    public init(
        text: String,
        role: String? = nil,
        label: String? = nil,
        isEditable: Bool = false
    ) {
        self.text = text
        self.role = role
        self.label = label
        self.isEditable = isEditable
    }
}

/// Information about an application
public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowName: String?
    public let browserURL: String?  // If app is a browser

    public init(
        bundleID: String,
        name: String,
        windowName: String? = nil,
        browserURL: String? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.windowName = windowName
        self.browserURL = browserURL
    }

    /// Known browser bundle IDs
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser"  // Arc
    ]

    public var isBrowser: Bool {
        Self.browserBundleIDs.contains(bundleID)
    }
}

/// Processing statistics
public struct ProcessingStatistics: Sendable {
    public let framesProcessed: Int
    public let averageOCRTimeMs: Double
    public let averageTextLength: Int
    public let errorCount: Int

    public init(
        framesProcessed: Int,
        averageOCRTimeMs: Double,
        averageTextLength: Int,
        errorCount: Int
    ) {
        self.framesProcessed = framesProcessed
        self.averageOCRTimeMs = averageOCRTimeMs
        self.averageTextLength = averageTextLength
        self.errorCount = errorCount
    }
}
