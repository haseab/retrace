import Foundation
import Shared
import Database
import Storage
import SQLCipher

/// Unified data adapter that owns connections directly and runs SQL
/// Seamlessly blends data from Retrace (native) and Rewind (encrypted) databases
public actor DataAdapter {

    // MARK: - Connections

    private let retraceConnection: DatabaseConnection
    private let retraceConfig: DatabaseConfig

    private var rewindConnection: DatabaseConnection?
    private var rewindConfig: DatabaseConfig?
    private var cutoffDate: Date?

    // MARK: - Image Extractors

    private let retraceImageExtractor: ImageExtractor
    private var rewindImageExtractor: ImageExtractor?

    // MARK: - Database Reference (for legacy APIs)

    private let database: DatabaseManager

    // MARK: - Cache

    private struct SegmentCacheKey: Hashable {
        let startDate: Date
        let endDate: Date
    }

    private struct SegmentCacheEntry {
        let segments: [Segment]
        let timestamp: Date
    }

    private var segmentCache: [SegmentCacheKey: SegmentCacheEntry] = [:]
    private let segmentCacheTTL: TimeInterval = 300

    // MARK: - State

    private var isInitialized = false

    // MARK: - Initialization

    public init(
        retraceConnection: DatabaseConnection,
        retraceConfig: DatabaseConfig,
        retraceImageExtractor: ImageExtractor,
        database: DatabaseManager
    ) {
        self.retraceConnection = retraceConnection
        self.retraceConfig = retraceConfig
        self.retraceImageExtractor = retraceImageExtractor
        self.database = database
    }

    /// Configure Rewind data source (encrypted SQLCipher database)
    public func configureRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        imageExtractor: ImageExtractor,
        cutoffDate: Date
    ) {
        self.rewindConnection = connection
        self.rewindConfig = config
        self.rewindImageExtractor = imageExtractor
        self.cutoffDate = cutoffDate
        Log.info("[DataAdapter] Rewind source configured with cutoff \(cutoffDate)", category: .app)
    }

    /// Initialize the adapter
    public func initialize() async throws {
        isInitialized = true
        Log.info("[DataAdapter] Initialized with \(rewindConnection != nil ? "2" : "1") connection(s)", category: .app)
    }

    /// Shutdown the adapter
    public func shutdown() async {
        isInitialized = false
        Log.info("[DataAdapter] Shutdown complete", category: .app)
    }

    // MARK: - Connection Selection

    private func connectionForTimestamp(_ timestamp: Date) -> (DatabaseConnection, DatabaseConfig) {
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            return (rewind, config)
        }
        return (retraceConnection, retraceConfig)
    }

    // MARK: - Frame Retrieval

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind if timestamp is before cutoff
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let frames = try queryFramesWithVideoInfo(from: startDate, to: effectiveEnd, limit: limit, connection: rewind, config: config)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let frames = try queryFramesWithVideoInfo(from: retraceStart, to: endDate, limit: limit, connection: retraceConnection, config: retraceConfig)
            allFrames.append(contentsOf: frames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get frames in a time range
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    /// Get most recent frames with video info
    public func getMostRecentFramesWithVideoInfo(limit: Int = 250) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Query Retrace
        let retraceFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: retraceConnection, config: retraceConfig)
        allFrames.append(contentsOf: retraceFrames)

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: rewind, config: config)
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get most recent frames
    public func getMostRecentFrames(limit: Int = 250) async throws -> [FrameReference] {
        let framesWithVideo = try await getMostRecentFramesWithVideoInfo(limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info before a timestamp
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let frames = try queryFramesWithVideoInfoBefore(timestamp: effectiveTimestamp, limit: limit, connection: rewind, config: config)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get frames before a timestamp
    public func getFramesBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info after a timestamp
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind (respecting cutoff)
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            let frames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: rewind, config: config)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get frames after a timestamp
    public func getFramesAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    /// Get the most recent frame timestamp
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        let frames = try await getMostRecentFrames(limit: 1)
        return frames.first?.timestamp
    }

    // MARK: - Image Extraction

    /// Get image data for a specific frame
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)

        // Get video info
        guard let videoInfo = try getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, connection: connection, config: config) else {
            throw DataAdapterError.frameNotFound
        }

        // Extract image based on source
        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrame(videoPath: videoInfo.videoPath, frameIndex: videoInfo.frameIndex, frameRate: videoInfo.frameRate)
        }
        return try await retraceImageExtractor.extractFrame(videoPath: videoInfo.videoPath, frameIndex: videoInfo.frameIndex, frameRate: videoInfo.frameRate)
    }

    /// Get image data for a frame by timestamp (auto-detects source)
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        // Determine source based on cutoff
        let source: FrameSource = (cutoffDate != nil && timestamp < cutoffDate! && rewindConnection != nil) ? .rewind : .native
        return try await getFrameImage(segmentID: segmentID, timestamp: timestamp, source: source)
    }

    /// Get frame image by exact videoID and frameIndex
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int, source frameSource: FrameSource) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)

        // Query video info directly
        let sql = """
            SELECT v.path, v.frameRate
            FROM video v
            WHERE v.id = ?
            LIMIT 1;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            throw DataAdapterError.frameNotFound
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, videoID.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataAdapterError.frameNotFound
        }

        guard let pathPtr = sqlite3_column_text(statement, 0) else {
            throw DataAdapterError.frameNotFound
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(statement, 1)

        let fullPath = "\(config.storageRoot)/\(videoPath)"

        // Extract image based on source
        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrame(videoPath: fullPath, frameIndex: frameIndex, frameRate: frameRate)
        }
        return try await retraceImageExtractor.extractFrame(videoPath: fullPath, frameIndex: frameIndex, frameRate: frameRate)
    }

    /// Get video info for a frame
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> FrameVideoInfo? {
        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)
        return try getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, connection: connection, config: config)
    }

    // MARK: - Segments

    /// Get segments in a time range
    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let cacheKey = SegmentCacheKey(startDate: startDate, endDate: endDate)

        // Check cache
        if let cached = segmentCache[cacheKey] {
            if Date().timeIntervalSince(cached.timestamp) < segmentCacheTTL {
                return cached.segments
            }
            segmentCache.removeValue(forKey: cacheKey)
        }

        var allSegments: [Segment] = []

        // Query Rewind
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let segments = try querySegments(from: startDate, to: effectiveEnd, connection: rewind, config: config)
            allSegments.append(contentsOf: segments)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let segments = try querySegments(from: retraceStart, to: endDate, connection: retraceConnection, config: retraceConfig)
            allSegments.append(contentsOf: segments)
        }

        // Sort by start time
        allSegments.sort { $0.startDate < $1.startDate }

        // Cache
        segmentCache[cacheKey] = SegmentCacheEntry(segments: allSegments, timestamp: Date())
        return allSegments
    }

    /// Invalidate the segment cache
    public func invalidateSessionCache() {
        segmentCache.removeAll()
    }

    // MARK: - OCR Nodes

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)

        return try getAllOCRNodes(timestamp: timestamp, connection: connection, config: config)
    }

    /// Get all OCR nodes for a frame by frameID
    public func getAllOCRNodes(frameID: FrameID, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let connection = frameSource == .rewind && rewindConnection != nil
            ? rewindConnection!
            : retraceConnection

        return try getAllOCRNodes(frameID: frameID, connection: connection)
    }

    // MARK: - App Discovery

    /// Get all distinct apps from all data sources
    public func getDistinctApps() async throws -> [AppInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        var bundleIDs: [String] = []

        // Try Rewind first (more historical data)
        if let rewind = rewindConnection {
            bundleIDs = try queryDistinctApps(connection: rewind)
        }

        // If empty, try Retrace
        if bundleIDs.isEmpty {
            bundleIDs = try queryDistinctApps(connection: retraceConnection)
        }

        return await AppNameResolver.resolveAll(bundleIDs: bundleIDs)
    }

    // MARK: - URL Bounding Box Detection

    /// Get bounding box for URL in a frame's OCR text
    public func getURLBoundingBox(timestamp: Date, source frameSource: FrameSource) async throws -> URLBoundingBox? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)

        return try getURLBoundingBox(timestamp: timestamp, connection: connection, config: config)
    }

    // MARK: - Full-Text Search

    /// Search across all data sources
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let startTime = Date()
        var allResults: [SearchResult] = []
        var totalCount = 0

        // Search Retrace
        do {
            let retraceResults = try searchConnection(query: query, connection: retraceConnection, config: retraceConfig, source: .native)
            allResults.append(contentsOf: retraceResults.results)
            totalCount += retraceResults.totalCount
        } catch {
            Log.warning("[DataAdapter] Retrace search failed: \(error)", category: .app)
        }

        // Search Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            do {
                var rewindResults = try searchConnection(query: query, connection: rewind, config: config, source: .rewind)
                rewindResults.results = rewindResults.results.map { result in
                    var modified = result
                    modified.source = .rewind
                    return modified
                }
                allResults.append(contentsOf: rewindResults.results)
                totalCount += rewindResults.totalCount
            } catch {
                Log.warning("[DataAdapter] Rewind search failed: \(error)", category: .app)
            }
        }

        // Sort by search mode
        switch query.mode {
        case .relevant:
            allResults.sort { $0.relevanceScore > $1.relevanceScore }
        case .all:
            allResults.sort { $0.timestamp > $1.timestamp }
        }

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return SearchResults(
            query: query,
            results: Array(allResults.prefix(query.limit)),
            totalCount: totalCount,
            searchTimeMs: searchTimeMs
        )
    }

    // MARK: - Deletion

    /// Delete a frame
    public func deleteFrame(frameID: FrameID, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let connection = frameSource == .rewind && rewindConnection != nil
            ? rewindConnection!
            : retraceConnection

        try deleteFrames(frameIDs: [frameID], connection: connection)
    }

    /// Delete multiple frames
    public func deleteFrames(_ frames: [(frameID: FrameID, source: FrameSource)]) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Group by source
        var framesBySource: [FrameSource: [FrameID]] = [:]
        for (frameID, source) in frames {
            framesBySource[source, default: []].append(frameID)
        }

        // Delete from each source
        for (source, frameIDs) in framesBySource {
            let connection = source == .rewind && rewindConnection != nil
                ? rewindConnection!
                : retraceConnection
            try deleteFrames(frameIDs: frameIDs, connection: connection)
        }
    }

    /// Delete frame by timestamp
    public func deleteFrameByTimestamp(_ timestamp: Date, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, retraceConfig)

        // Find frame by timestamp
        let sql = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1;"
        guard let statement = try? connection.prepare(sql: sql) else {
            throw DataAdapterError.frameNotFound
        }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataAdapterError.frameNotFound
        }

        let frameID = FrameID(value: sqlite3_column_int64(statement, 0))
        try deleteFrames(frameIDs: [frameID], connection: connection)
    }

    // MARK: - Source Information

    /// Get registered sources
    public var registeredSources: [FrameSource] {
        var sources: [FrameSource] = [.native]
        if rewindConnection != nil {
            sources.append(.rewind)
        }
        return sources
    }

    /// Check if source is available
    public func isSourceAvailable(_ source: FrameSource) -> Bool {
        if source == .native { return true }
        if source == .rewind { return rewindConnection != nil }
        return false
    }

    // MARK: - Private SQL Query Methods

    private func queryFramesWithVideoInfo(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [FrameWithVideoInfo] {
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else { return [] }

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                f.encodingStatus,
                s.bundleID,
                s.windowName,
                s.browserUrl,
                v.path,
                v.frameRate,
                v.width,
                v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(effectiveEndDate, to: statement, at: 2)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryMostRecentFramesWithVideoInfo(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFramesWithVideoInfoBefore(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt < ?
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(effectiveTimestamp, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFramesWithVideoInfoAfter(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt > ?
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func getFrameVideoInfo(
        segmentID: VideoSegmentID,
        timestamp: Date,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameVideoInfo? {
        let sql = """
            SELECT v.id, v.path, v.width, v.height, v.frameRate, f.videoFrameIndex
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return nil }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        guard let relativePath = getTextOrNil(statement, 1) else { return nil }

        let width = Int(sqlite3_column_int(statement, 2))
        let height = Int(sqlite3_column_int(statement, 3))
        let frameRate = sqlite3_column_double(statement, 4)
        let frameIndex = Int(sqlite3_column_int(statement, 5))

        let fullPath = "\(config.storageRoot)/\(relativePath)"

        return FrameVideoInfo(
            videoPath: fullPath,
            frameIndex: frameIndex,
            frameRate: frameRate,
            width: width,
            height: height
        )
    }

    private func querySegments(
        from startDate: Date,
        to endDate: Date,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE startDate >= ? AND startDate <= ?
            ORDER BY startDate ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(endDate, to: statement, at: 2)

        var segments: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let segment = try? parseSegment(statement: statement, config: config) {
                segments.append(segment)
            }
        }

        return segments
    }

    private func getAllOCRNodes(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> [OCRNodeWithText] {
        // First find the frame ID
        let frameSql = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1;"
        guard let frameStatement = try? connection.prepare(sql: frameSql) else { return [] }
        defer { connection.finalize(frameStatement) }

        config.bindDate(timestamp, to: frameStatement, at: 1)

        guard sqlite3_step(frameStatement) == SQLITE_ROW else { return [] }

        let frameID = FrameID(value: sqlite3_column_int64(frameStatement, 0))
        return try getAllOCRNodes(frameID: frameID, connection: connection)
    }

    private func getAllOCRNodes(frameID: FrameID, connection: DatabaseConnection) throws -> [OCRNodeWithText] {
        let sql = """
            SELECT
                n.id,
                n.nodeOrder,
                n.textOffset,
                n.textLength,
                n.leftX,
                n.topY,
                n.width,
                n.height,
                (COALESCE(sc.c0, '') || COALESCE(sc.c1, '')) as fullText
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var nodes: [OCRNodeWithText] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let node = parseOCRNodeFromRow(statement: statement) {
                nodes.append(node)
            }
        }

        return nodes
    }

    private func queryDistinctApps(connection: DatabaseConnection) throws -> [String] {
        let sql = """
            SELECT bundleID, COUNT(*) as usage_count
            FROM segment
            WHERE bundleID IS NOT NULL AND bundleID != ''
            GROUP BY bundleID
            ORDER BY usage_count DESC
            LIMIT 100;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bundleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIDPtr = sqlite3_column_text(statement, 0) else { continue }
            bundleIDs.append(String(cString: bundleIDPtr))
        }

        return bundleIDs
    }

    private func getURLBoundingBox(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> URLBoundingBox? {
        // Get frameId and browserUrl
        let frameSQL = """
            SELECT f.id, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let frameStmt = try? connection.prepare(sql: frameSQL) else { return nil }
        defer { connection.finalize(frameStmt) }

        config.bindDate(timestamp, to: frameStmt, at: 1)

        guard sqlite3_step(frameStmt) == SQLITE_ROW else { return nil }

        let frameId = sqlite3_column_int64(frameStmt, 0)
        guard let browserUrlPtr = sqlite3_column_text(frameStmt, 1) else { return nil }
        let browserUrl = String(cString: browserUrlPtr)
        guard !browserUrl.isEmpty else { return nil }

        // Get FTS content
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        guard let ftsStmt = try? connection.prepare(sql: ftsSQL) else { return nil }
        defer { connection.finalize(ftsStmt) }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else { return nil }

        let c0Text = sqlite3_column_text(ftsStmt, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text

        // Get nodes
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        guard let nodesStmt = try? connection.prepare(sql: nodesSQL) else { return nil }
        defer { connection.finalize(nodesStmt) }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        let domain = URL(string: browserUrl)?.host ?? browserUrl
        var bestMatch: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let textOffset = Int(sqlite3_column_int(nodesStmt, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt, 6))

            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])
            guard nodeText.lowercased().contains(domain.lowercased()) else { continue }

            var score = 0
            let urlRatio = Double(domain.count) / Double(nodeText.count)
            if urlRatio > 0.6 { score += 100 }
            else if urlRatio > 0.3 { score += 50 }
            else { score += 10 }

            if topY > 0.07 && topY < 0.15 { score += 50 }
            else if topY < 0.07 { score += 20 }

            if nodeText.contains("/") && !nodeText.contains(" ") { score += 30 }

            if let current = bestMatch {
                if score > current.score {
                    bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
                }
            } else {
                bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
            }
        }

        guard let bounds = bestMatch else { return nil }

        return URLBoundingBox(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            url: browserUrl
        )
    }

    private func searchConnection(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource
    ) throws -> SearchResults {
        switch query.mode {
        case .relevant:
            return try searchRelevant(query: query, connection: connection, config: config, source: source)
        case .all:
            return try searchAll(query: query, connection: connection, config: config, source: source)
        }
    }

    private func searchRelevant(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource
    ) throws -> SearchResults {
        let startTime = Date()
        let ftsQuery = buildFTSQuery(query.text)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Phase 1: Pure FTS search
        let relevanceLimit = 50
        let ftsSQL = """
            SELECT rowid, snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet, bm25(searchRanking) as rank
            FROM searchRanking
            WHERE searchRanking MATCH ?
            ORDER BY bm25(searchRanking)
            LIMIT ?
        """

        guard let ftsStatement = try? connection.prepare(sql: ftsSQL) else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(ftsStatement) }

        sqlite3_bind_text(ftsStatement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(ftsStatement, 2, Int32(relevanceLimit))

        var ftsResults: [(rowid: Int64, snippet: String, rank: Double)] = []
        while sqlite3_step(ftsStatement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(ftsStatement, 0)
            let snippet = sqlite3_column_text(ftsStatement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(ftsStatement, 2)
            ftsResults.append((rowid: rowid, snippet: snippet, rank: rank))
        }

        guard !ftsResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: elapsed)
        }

        // Phase 2: Join to get metadata
        let rowids = ftsResults.map { $0.rowid }
        let rowidPlaceholders = rowids.map { _ in "?" }.joined(separator: ", ")

        var whereConditions = ["ds.docid IN (\(rowidPlaceholders))"]
        var extraBindValues: [Any] = []

        if let cutoffDate = config.cutoffDate {
            whereConditions.append("f.createdAt < ?")
            extraBindValues.append(config.formatDate(cutoffDate))
        }

        if let startDate = query.filters.startDate {
            whereConditions.append("f.createdAt >= ?")
            extraBindValues.append(config.formatDate(startDate))
        }
        if let endDate = query.filters.endDate {
            whereConditions.append("f.createdAt <= ?")
            extraBindValues.append(config.formatDate(endDate))
        }

        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let appPlaceholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            whereConditions.append("s.bundleID IN (\(appPlaceholders))")
            extraBindValues.append(contentsOf: appBundleIDs)
        }

        let whereClause = whereConditions.joined(separator: " AND ")

        let metadataSQL = """
            SELECT
                ds.docid,
                f.id as frame_id,
                f.createdAt as timestamp,
                s.id as segment_id,
                s.bundleID as app_bundle_id,
                s.windowName as window_title,
                f.videoId as video_id,
                f.videoFrameIndex as frame_index
            FROM doc_segment ds
            JOIN frame f ON ds.frameId = f.id
            JOIN segment s ON f.segmentId = s.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ? OFFSET ?
        """

        guard let metaStatement = try? connection.prepare(sql: metadataSQL) else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: elapsed)
        }
        defer { connection.finalize(metaStatement) }

        var bindIndex: Int32 = 1
        for rowid in rowids {
            sqlite3_bind_int64(metaStatement, bindIndex, rowid)
            bindIndex += 1
        }

        for value in extraBindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(metaStatement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(metaStatement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.offset))

        let ftsLookup = Dictionary(uniqueKeysWithValues: ftsResults.map { ($0.rowid, (snippet: $0.snippet, rank: $0.rank)) })

        var results: [SearchResult] = []

        while sqlite3_step(metaStatement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(metaStatement, 0)
            let frameId = sqlite3_column_int64(metaStatement, 1)
            let segmentId = sqlite3_column_int64(metaStatement, 3)
            let appBundleID = sqlite3_column_text(metaStatement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(metaStatement, 5).map { String(cString: $0) }
            let videoId = sqlite3_column_int64(metaStatement, 6)
            let frameIndex = Int(sqlite3_column_int(metaStatement, 7))

            guard let ftsData = ftsLookup[docid] else { continue }
            let snippet = ftsData.snippet
            let rank = ftsData.rank

            let appName = appBundleID?.components(separatedBy: ".").last
            let timestamp = config.parseDate(from: metaStatement, column: 2) ?? Date()

            let cleanSnippet = snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: FrameID(value: frameId),
                timestamp: timestamp,
                snippet: cleanSnippet,
                matchedText: query.text,
                relevanceScore: abs(rank) / (1.0 + abs(rank)),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: segmentId),
                videoID: VideoSegmentID(value: videoId),
                frameIndex: frameIndex,
                source: source
            )

            results.append(result)
        }

        let totalElapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        return SearchResults(query: query, results: results, totalCount: min(ftsResults.count, relevanceLimit), searchTimeMs: totalElapsed)
    }

    private func searchAll(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource
    ) throws -> SearchResults {
        let startTime = Date()
        let ftsQuery = buildFTSQuery(query.text)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var whereConditions: [String] = []
        var bindValues: [Any] = []

        if let cutoffDate = config.cutoffDate {
            whereConditions.append("f.createdAt < ?")
            bindValues.append(config.formatDate(cutoffDate))
        }

        if let startDate = query.filters.startDate {
            whereConditions.append("f.createdAt >= ?")
            bindValues.append(config.formatDate(startDate))
        }
        if let endDate = query.filters.endDate {
            whereConditions.append("f.createdAt <= ?")
            bindValues.append(config.formatDate(endDate))
        }

        let needsSegmentJoin = query.filters.appBundleIDs != nil
        var appFilterClause = ""
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let placeholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            appFilterClause = "AND s.bundleID IN (\(placeholders))"
            bindValues.append(contentsOf: appBundleIDs)
        }

        let whereClause = whereConditions.isEmpty ? "1=1" : whereConditions.joined(separator: " AND ")
        let recentFramesLimit = 10000

        let sql: String
        if needsSegmentJoin {
            sql = """
                SELECT
                    ds.docid as docid,
                    snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet,
                    bm25(searchRanking) as rank,
                    recent_frames.frame_id,
                    recent_frames.timestamp,
                    recent_frames.segment_id,
                    recent_frames.video_id,
                    recent_frames.frame_index
                FROM (
                    SELECT f.id as frame_id, f.createdAt as timestamp, f.segmentId as segment_id, f.videoId as video_id, f.videoFrameIndex as frame_index
                    FROM frame f
                    JOIN segment s ON f.segmentId = s.id
                    WHERE \(whereClause) \(appFilterClause)
                    ORDER BY f.createdAt DESC
                    LIMIT \(recentFramesLimit)
                ) recent_frames
                JOIN doc_segment ds ON ds.frameId = recent_frames.frame_id
                JOIN searchRanking ON searchRanking.rowid = ds.docid
                WHERE searchRanking MATCH ?
                ORDER BY recent_frames.timestamp DESC
                LIMIT ? OFFSET ?
            """
        } else {
            sql = """
                SELECT
                    ds.docid as docid,
                    snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet,
                    bm25(searchRanking) as rank,
                    recent_frames.frame_id,
                    recent_frames.timestamp,
                    recent_frames.segment_id,
                    recent_frames.video_id,
                    recent_frames.frame_index
                FROM (
                    SELECT f.id as frame_id, f.createdAt as timestamp, f.segmentId as segment_id, f.videoId as video_id, f.videoFrameIndex as frame_index
                    FROM frame f
                    WHERE \(whereClause)
                    ORDER BY f.createdAt DESC
                    LIMIT \(recentFramesLimit)
                ) recent_frames
                JOIN doc_segment ds ON ds.frameId = recent_frames.frame_id
                JOIN searchRanking ON searchRanking.rowid = ds.docid
                WHERE searchRanking MATCH ?
                ORDER BY recent_frames.timestamp DESC
                LIMIT ? OFFSET ?
            """
        }

        guard let statement = try? connection.prepare(sql: sql) else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1

        for value in bindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(statement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        sqlite3_bind_int(statement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(query.offset))

        var frameResults: [(docid: Int64, snippet: String, rank: Double, frameId: Int64, timestamp: Date, segmentId: Int64, videoId: Int64, frameIndex: Int)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(statement, 0)
            let snippet = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(statement, 2)
            let frameId = sqlite3_column_int64(statement, 3)
            let segmentId = sqlite3_column_int64(statement, 5)
            let videoId = sqlite3_column_int64(statement, 6)
            let frameIndex = Int(sqlite3_column_int(statement, 7))

            let timestamp = config.parseDate(from: statement, column: 4) ?? Date()
            frameResults.append((docid: docid, snippet: snippet, rank: rank, frameId: frameId, timestamp: timestamp, segmentId: segmentId, videoId: videoId, frameIndex: frameIndex))
        }

        guard !frameResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let totalCount = getSearchTotalCount(ftsQuery: ftsQuery, connection: connection)
            return SearchResults(query: query, results: [], totalCount: totalCount, searchTimeMs: elapsed)
        }

        let segmentIds = Array(Set(frameResults.map { $0.segmentId }))
        let segmentMetadata = fetchSegmentMetadata(segmentIds: segmentIds, connection: connection)

        var results: [SearchResult] = []

        for frame in frameResults {
            let segmentMeta = segmentMetadata[frame.segmentId]
            let appBundleID = segmentMeta?.bundleID
            let windowName = segmentMeta?.windowName
            let appName = appBundleID?.components(separatedBy: ".").last

            let cleanSnippet = frame.snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: FrameID(value: frame.frameId),
                timestamp: frame.timestamp,
                snippet: cleanSnippet,
                matchedText: query.text,
                relevanceScore: abs(frame.rank) / (1.0 + abs(frame.rank)),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: frame.segmentId),
                videoID: VideoSegmentID(value: frame.videoId),
                frameIndex: frame.frameIndex,
                source: source
            )

            results.append(result)
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        let totalCount = getSearchTotalCount(ftsQuery: ftsQuery, connection: connection)

        return SearchResults(query: query, results: results, totalCount: totalCount, searchTimeMs: elapsed)
    }

    private func fetchSegmentMetadata(segmentIds: [Int64], connection: DatabaseConnection) -> [Int64: (bundleID: String?, windowName: String?)] {
        guard !segmentIds.isEmpty else { return [:] }

        let placeholders = segmentIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, bundleID, windowName FROM segment WHERE id IN (\(placeholders))"

        guard let statement = try? connection.prepare(sql: sql) else { return [:] }
        defer { connection.finalize(statement) }

        for (index, segmentId) in segmentIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), segmentId)
        }

        var metadata: [Int64: (bundleID: String?, windowName: String?)] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            metadata[id] = (bundleID: bundleID, windowName: windowName)
        }

        return metadata
    }

    private func buildFTSQuery(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word -> String in
                let escaped = word
                    .replacingOccurrences(of: "\"", with: "\"\"")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: ":", with: "")
                return "\"\(escaped)\"*"
            }

        return words.joined(separator: " ")
    }

    private func getSearchTotalCount(ftsQuery: String, connection: DatabaseConnection) -> Int {
        let countSQL = """
            SELECT COUNT(*)
            FROM searchRanking
            WHERE searchRanking MATCH ?
        """

        guard let countStmt = try? connection.prepare(sql: countSQL) else { return 0 }
        defer { connection.finalize(countStmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(countStmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)

        if sqlite3_step(countStmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(countStmt, 0))
        }

        return 0
    }

    private func deleteFrames(frameIDs: [FrameID], connection: DatabaseConnection) throws {
        guard !frameIDs.isEmpty else { return }

        try connection.beginTransaction()

        do {
            for frameID in frameIDs {
                // Delete OCR nodes
                let deleteNodesSql = "DELETE FROM node WHERE frameId = ?;"
                if let stmt = try? connection.prepare(sql: deleteNodesSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }

                // Delete doc_segment entries
                let deleteDocSegmentSql = "DELETE FROM doc_segment WHERE frameId = ?;"
                if let stmt = try? connection.prepare(sql: deleteDocSegmentSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }

                // Delete frame itself
                let deleteFrameSql = "DELETE FROM frame WHERE id = ?;"
                if let stmt = try? connection.prepare(sql: deleteFrameSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }
            }

            try connection.commit()
        } catch {
            try connection.rollback()
            throw error
        }
    }

    // MARK: - Row Parsing

    private func parseFrameWithVideoInfo(statement: OpaquePointer, config: DatabaseConfig) throws -> FrameWithVideoInfo {
        let id = FrameID(value: sqlite3_column_int64(statement, 0))

        guard let timestamp = config.parseDate(from: statement, column: 1) else {
            throw DataAdapterError.parseFailed
        }

        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        let encodingStatusText = sqlite3_column_text(statement, 5)
        let encodingStatusString = encodingStatusText != nil ? String(cString: encodingStatusText!) : "pending"
        let encodingStatus = EncodingStatus(rawValue: encodingStatusString) ?? .pending

        let bundleID = getTextOrNil(statement, 6) ?? ""
        let windowName = getTextOrNil(statement, 7)
        let browserUrl = getTextOrNil(statement, 8)

        let videoPath = getTextOrNil(statement, 9)
        let frameRate = sqlite3_column_type(statement, 10) != SQLITE_NULL ? sqlite3_column_double(statement, 10) : nil
        let width = sqlite3_column_type(statement, 11) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 11)) : nil
        let height = sqlite3_column_type(statement, 12) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 12)) : nil

        let metadata = FrameMetadata(
            appBundleID: bundleID.isEmpty ? nil : bundleID,
            appName: bundleID.components(separatedBy: ".").last,
            windowName: windowName,
            browserURL: browserUrl,
            displayID: 0
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: config.source
        )

        let videoInfo: FrameVideoInfo?
        if let relativePath = videoPath, let rate = frameRate, let w = width, let h = height {
            let fullPath = "\(config.storageRoot)/\(relativePath)"
            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: videoFrameIndex,
                frameRate: rate,
                width: w,
                height: h
            )
        } else {
            videoInfo = nil
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo)
    }

    private func parseSegment(statement: OpaquePointer, config: DatabaseConfig) throws -> Segment {
        let id = SegmentID(value: sqlite3_column_int64(statement, 0))
        let bundleID = getTextOrNil(statement, 1) ?? ""

        guard let startDate = config.parseDate(from: statement, column: 2),
              let endDate = config.parseDate(from: statement, column: 3) else {
            throw DataAdapterError.parseFailed
        }

        let windowName = getTextOrNil(statement, 4)
        let browserUrl = getTextOrNil(statement, 5)
        let type = Int(sqlite3_column_int(statement, 6))

        return Segment(
            id: id,
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }

    private func parseOCRNodeFromRow(statement: OpaquePointer) -> OCRNodeWithText? {
        let id = Int(sqlite3_column_int64(statement, 0))
        let textOffset = Int(sqlite3_column_int(statement, 2))
        let textLength = Int(sqlite3_column_int(statement, 3))
        let leftX = sqlite3_column_double(statement, 4)
        let topY = sqlite3_column_double(statement, 5)
        let width = sqlite3_column_double(statement, 6)
        let height = sqlite3_column_double(statement, 7)

        guard let fullTextCStr = sqlite3_column_text(statement, 8) else { return nil }
        let fullText = String(cString: fullTextCStr)

        let startIndex = fullText.index(
            fullText.startIndex,
            offsetBy: textOffset,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        let endIndex = fullText.index(
            startIndex,
            offsetBy: textLength,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        let text = String(fullText[startIndex..<endIndex])

        return OCRNodeWithText(
            id: id,
            x: leftX,
            y: topY,
            width: width,
            height: height,
            text: text
        )
    }

    private func getTextOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}

// MARK: - Errors

public enum DataAdapterError: Error, LocalizedError {
    case notInitialized
    case sourceNotAvailable(FrameSource)
    case noSourceForTimestamp(Date)
    case frameNotFound
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "DataAdapter not initialized"
        case .sourceNotAvailable(let source):
            return "Data source not available: \(source.displayName)"
        case .noSourceForTimestamp(let date):
            return "No data source available for timestamp: \(date)"
        case .frameNotFound:
            return "Frame not found"
        case .parseFailed:
            return "Failed to parse database row"
        }
    }
}
