import Foundation

// MARK: - Text Source

/// Source of extracted text
public enum TextSource: String, Codable, Sendable {
    case ocr           // Extracted via Vision framework OCR
    case accessibility // Extracted via Accessibility API
    case merged        // Combined from multiple sources
}

// MARK: - OCR Text Region (Processing)

/// A region of text from OCR with normalized bounding box (0-1 coordinates)
/// Used during processing before converting to pixel coordinates for storage
public struct OCRTextRegion: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float  // 0.0 to 1.0
    public let boundingBox: NormalizedRect
    public let source: TextSource

    public init(
        text: String,
        confidence: Float = 1.0,
        boundingBox: NormalizedRect = .zero,
        source: TextSource = .ocr
    ) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.source = source
    }
}

/// Normalized rectangle (0-1 coordinates, origin bottom-left like Vision)
public struct NormalizedRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)
}

// MARK: - Extracted Text

/// All text extracted from a single frame
/// Separates main content from UI chrome (menu bar, dock) for better search relevance
public struct ExtractedText: Codable, Sendable {
    public let frameID: FrameID
    public let timestamp: Date
    public let regions: [TextRegion]       // Main content regions (c0)
    public let chromeRegions: [TextRegion] // UI chrome regions (c1) - menu bar, dock, status bar
    public let fullText: String            // Main content text concatenated for indexing (c0)
    public let chromeText: String          // UI chrome text concatenated (c1)
    public let metadata: FrameMetadata

    public init(
        frameID: FrameID,
        timestamp: Date,
        regions: [TextRegion],
        chromeRegions: [TextRegion] = [],
        fullText: String? = nil,
        chromeText: String? = nil,
        metadata: FrameMetadata = .empty
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.regions = regions
        self.chromeRegions = chromeRegions
        self.fullText = fullText ?? regions.map(\.text).joined(separator: " ")
        self.chromeText = chromeText ?? chromeRegions.map(\.text).joined(separator: " ")
        self.metadata = metadata
    }

    public var isEmpty: Bool {
        fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var wordCount: Int {
        fullText.split(separator: " ").count
    }
}

// MARK: - Indexed Document

/// A document stored in the search index
public struct IndexedDocument: Codable, Sendable {
    public let id: Int64  // SQLite rowid
    public let frameID: FrameID
    public let timestamp: Date
    public let content: String
    public let appName: String?
    public let windowName: String?
    public let browserURL: String?

    public init(
        id: Int64,
        frameID: FrameID,
        timestamp: Date,
        content: String,
        appName: String? = nil,
        windowName: String? = nil,
        browserURL: String? = nil
    ) {
        self.id = id
        self.frameID = frameID
        self.timestamp = timestamp
        self.content = content
        self.appName = appName
        self.windowName = windowName
        self.browserURL = browserURL
    }
}
