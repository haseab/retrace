import Foundation
import CoreGraphics

// MARK: - Database Protocol

/// Core database operations for frame and text storage
/// Owner: DATABASE agent
///
/// Thread Safety: Implementations must be actors to ensure serialized database access
public protocol DatabaseProtocol: Actor {

    // MARK: - Lifecycle

    /// Initialize the database, run migrations if needed
    func initialize() async throws

    /// Close the database connection gracefully
    func close() async throws

    // MARK: - Frame Operations

    /// Insert a new frame reference and return the auto-generated ID
    func insertFrame(_ frame: FrameReference) async throws -> Int64

    /// Get a frame by ID
    func getFrame(id: FrameID) async throws -> FrameReference?

    /// Get frames in a time range
    func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames in descending order (newest of the older batch first)
    func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames in ascending order (oldest of the newer batch first)
    func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames for a specific app
    func getFrames(appBundleID: String, limit: Int, offset: Int) async throws -> [FrameReference]

    /// Delete frames older than a date
    func deleteFrames(olderThan date: Date) async throws -> Int

    /// Get total frame count
    func getFrameCount() async throws -> Int

    /// Update frame's videoId and videoFrameIndex after video encoding
    func updateFrameVideoLink(frameID: FrameID, videoID: VideoSegmentID, frameIndex: Int) async throws

    // MARK: - Video Segment Operations (Video Files)

    /// Insert a new video segment (150-frame video chunk) and return the auto-generated ID
    func insertVideoSegment(_ segment: VideoSegment) async throws -> Int64

    /// Get video segment by ID
    func getVideoSegment(id: VideoSegmentID) async throws -> VideoSegment?

    /// Get video segment containing a specific timestamp
    func getVideoSegment(containingTimestamp date: Date) async throws -> VideoSegment?

    /// Get all video segments in a time range
    func getVideoSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment]

    /// Delete a video segment and its associated frames
    func deleteVideoSegment(id: VideoSegmentID) async throws

    /// Get total storage used by all video segments
    func getTotalStorageBytes() async throws -> Int64

    // MARK: - Text/Document Operations

    /// Insert extracted text for indexing
    func insertDocument(_ document: IndexedDocument) async throws -> Int64

    /// Update an existing document
    func updateDocument(id: Int64, content: String) async throws

    /// Delete a document
    func deleteDocument(id: Int64) async throws

    /// Get document by frame ID
    func getDocument(frameID: FrameID) async throws -> IndexedDocument?

    // MARK: - Segment Operations (App Focus Sessions - Rewind Compatible)

    /// Insert a new segment (app focus session)
    func insertSegment(
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int
    ) async throws -> Int64

    /// Update a segment's end date
    func updateSegmentEndDate(id: Int64, endDate: Date) async throws

    /// Get segment by ID
    func getSegment(id: Int64) async throws -> Segment?

    /// Get all segments in a time range
    func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment]

    /// Get the most recent segment
    func getMostRecentSegment() async throws -> Segment?

    /// Get segments for a specific app
    func getSegments(bundleID: String, limit: Int) async throws -> [Segment]

    /// Delete a segment
    func deleteSegment(id: Int64) async throws

    // MARK: - OCR Node Operations (Rewind-compatible)

    /// Insert OCR nodes for a frame with text already in searchRanking_content
    /// Nodes must have textOffset/textLength that reference the FTS content
    func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws

    /// Get all OCR nodes for a frame (without text extraction)
    /// Returns nodes with denormalized pixel coordinates
    func getNodes(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [OCRNode]

    /// Get OCR nodes with their text extracted from searchRanking_content
    /// Returns array of (node, text) tuples
    func getNodesWithText(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [(node: OCRNode, text: String)]

    /// Delete all OCR nodes for a frame
    func deleteNodes(frameID: FrameID) async throws

    // MARK: - FTS Content Operations (Rewind-compatible)

    /// Index a frame's OCR text into searchRanking_content and doc_segment
    /// This is the Rewind-compatible pattern:
    /// 1. INSERT INTO searchRanking_content (c0, c1, c2) → get docid
    /// 2. INSERT INTO doc_segment (docid, segmentId, frameId)
    ///
    /// - Parameters:
    ///   - mainText: Main OCR text (c0) - concatenated text from all nodes
    ///   - chromeText: UI chrome text (c1) - status bar, menu bar text (optional)
    ///   - windowTitle: Window title (c2) - from app metadata
    ///   - segmentId: Segment ID for the app focus session
    ///   - frameId: Frame ID for the screenshot
    /// - Returns: The docid for reference by nodes
    func indexFrameText(
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) async throws -> Int64

    /// Get the docid for a frame (for node text extraction)
    func getDocidForFrame(frameId: Int64) async throws -> Int64?

    /// Get FTS content by docid
    func getFTSContent(docid: Int64) async throws -> (mainText: String, chromeText: String?, windowTitle: String?)?

    /// Delete FTS content for a frame
    func deleteFTSContent(frameId: Int64) async throws

    // MARK: - Statistics

    /// Get database statistics
    func getStatistics() async throws -> DatabaseStatistics
}

// MARK: - FTS Protocol

/// Full-text search operations (separate for clarity)
/// Owner: DATABASE agent
public protocol FTSProtocol: Actor {

    /// Search the FTS index with a query string
    func search(query: String, limit: Int, offset: Int) async throws -> [FTSMatch]

    /// Search with filters
    func search(
        query: String,
        filters: SearchFilters,
        limit: Int,
        offset: Int
    ) async throws -> [FTSMatch]

    /// Get match count for a query (for pagination)
    func getMatchCount(query: String, filters: SearchFilters) async throws -> Int

    /// Rebuild the FTS index (maintenance operation)
    func rebuildIndex() async throws

    /// Optimize the FTS index
    func optimizeIndex() async throws
}

// MARK: - Supporting Types

/// A match from the FTS index
public struct FTSMatch: Sendable {
    public let documentID: Int64
    public let frameID: FrameID
    public let timestamp: Date
    public let snippet: String      // Highlighted snippet from FTS
    public let rank: Double         // FTS relevance rank
    public let appName: String?
    public let windowName: String?
    public let videoID: VideoSegmentID
    public let frameIndex: Int

    public init(
        documentID: Int64,
        frameID: FrameID,
        timestamp: Date,
        snippet: String,
        rank: Double,
        appName: String? = nil,
        windowName: String? = nil,
        videoID: VideoSegmentID,
        frameIndex: Int
    ) {
        self.documentID = documentID
        self.frameID = frameID
        self.timestamp = timestamp
        self.snippet = snippet
        self.rank = rank
        self.appName = appName
        self.windowName = windowName
        self.videoID = videoID
        self.frameIndex = frameIndex
    }
}

/// Database statistics
public struct DatabaseStatistics: Sendable {
    public let frameCount: Int
    public let segmentCount: Int
    public let documentCount: Int
    public let databaseSizeBytes: Int64
    public let oldestFrameDate: Date?
    public let newestFrameDate: Date?

    public init(
        frameCount: Int,
        segmentCount: Int,
        documentCount: Int,
        databaseSizeBytes: Int64,
        oldestFrameDate: Date?,
        newestFrameDate: Date?
    ) {
        self.frameCount = frameCount
        self.segmentCount = segmentCount
        self.documentCount = documentCount
        self.databaseSizeBytes = databaseSizeBytes
        self.oldestFrameDate = oldestFrameDate
        self.newestFrameDate = newestFrameDate
    }
}

// MARK: - OCR Node Model

/// Represents an OCR text bounding box from the Rewind-compatible node table
/// References text stored in searchRanking_content via textOffset/textLength
public struct OCRNode: Sendable, Equatable, Identifiable {
    /// Database row ID
    public let id: Int64?

    /// Reading order index (0, 1, 2, ...)
    /// Determines the sequence for text selection and concatenation
    public let nodeOrder: Int

    /// Character offset into searchRanking_content.c0
    /// Points to where this node's text starts in the full-text string
    public let textOffset: Int

    /// Length of text in characters
    /// How many characters from textOffset belong to this node
    public let textLength: Int

    /// Bounding box in pixel coordinates
    /// Denormalized from the 0.0-1.0 stored values
    public let bounds: CGRect

    /// Which window (0 = primary, nil = single window)
    /// Used for multi-window text separation
    public let windowIndex: Int?

    public init(
        id: Int64? = nil,
        nodeOrder: Int,
        textOffset: Int,
        textLength: Int,
        bounds: CGRect,
        windowIndex: Int? = nil
    ) {
        self.id = id
        self.nodeOrder = nodeOrder
        self.textOffset = textOffset
        self.textLength = textLength
        self.bounds = bounds
        self.windowIndex = windowIndex
    }

    /// X coordinate in pixels
    public var x: Int { Int(bounds.origin.x) }

    /// Y coordinate in pixels
    public var y: Int { Int(bounds.origin.y) }

    /// Width in pixels
    public var width: Int { Int(bounds.width) }

    /// Height in pixels
    public var height: Int { Int(bounds.height) }

    /// Center point of the node
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Whether this node contains a given point
    public func contains(_ point: CGPoint) -> Bool {
        bounds.contains(point)
    }

    /// Whether this node intersects with another
    public func intersects(_ other: OCRNode) -> Bool {
        bounds.intersects(other.bounds)
    }
}

/// OCR Node with normalized coordinates (0.0-1.0) and text content
/// Used for text selection UI layer - compatible with both Rewind and Retrace data
public struct OCRNodeWithText: Identifiable, Equatable, Sendable {
    public let id: Int  // nodeOrder from database
    /// Normalized X coordinate (0.0-1.0)
    public let x: CGFloat
    /// Normalized Y coordinate (0.0-1.0)
    public let y: CGFloat
    /// Normalized width (0.0-1.0)
    public let width: CGFloat
    /// Normalized height (0.0-1.0)
    public let height: CGFloat
    /// The text content of this node
    public let text: String

    public init(id: Int, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, text: String) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
    }
}
