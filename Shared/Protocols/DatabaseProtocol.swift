import Foundation

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

    /// Insert a new frame reference
    func insertFrame(_ frame: FrameReference) async throws

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

    // MARK: - Segment Operations

    /// Insert a new video segment
    func insertSegment(_ segment: VideoSegment) async throws

    /// Get segment by ID
    func getSegment(id: SegmentID) async throws -> VideoSegment?

    /// Get segment containing a specific timestamp
    func getSegment(containingTimestamp date: Date) async throws -> VideoSegment?

    /// Get all segments in a time range
    func getSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment]

    /// Delete a segment and its associated frames
    func deleteSegment(id: SegmentID) async throws

    /// Get total storage used by all segments
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

    // MARK: - App Session Operations

    /// Insert a new app session
    func insertSession(_ session: AppSession) async throws

    /// Update a session's end time (to close it)
    func updateSessionEndTime(id: AppSessionID, endTime: Date) async throws

    /// Get session by ID
    func getSession(id: AppSessionID) async throws -> AppSession?

    /// Get all sessions in a time range
    func getSessions(from startDate: Date, to endDate: Date) async throws -> [AppSession]

    /// Get the currently active session (where endTime is NULL)
    func getActiveSession() async throws -> AppSession?

    /// Get sessions for a specific app
    func getSessions(appBundleID: String, limit: Int) async throws -> [AppSession]

    /// Delete a session
    func deleteSession(id: AppSessionID) async throws

    // MARK: - Text Region Operations

    /// Insert a text region (OCR bounding box)
    func insertTextRegion(_ region: TextRegion) async throws

    /// Get all text regions for a frame
    func getTextRegions(frameID: FrameID) async throws -> [TextRegion]

    /// Get text regions in a specific area of a frame
    func getTextRegions(frameID: FrameID, inRect rect: CGRect) async throws -> [TextRegion]

    /// Delete text regions for a frame
    func deleteTextRegions(frameID: FrameID) async throws

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
    public let windowTitle: String?

    public init(
        documentID: Int64,
        frameID: FrameID,
        timestamp: Date,
        snippet: String,
        rank: Double,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.documentID = documentID
        self.frameID = frameID
        self.timestamp = timestamp
        self.snippet = snippet
        self.rank = rank
        self.appName = appName
        self.windowTitle = windowTitle
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
