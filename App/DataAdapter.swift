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
    private var cachedHiddenTagId: Int64?

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

    /// Disconnect Rewind data source (clears connection without deleting data)
    public func disconnectRewind() {
        guard rewindConnection != nil else {
            Log.info("[DataAdapter] No Rewind source to disconnect", category: .app)
            return
        }
        self.rewindConnection = nil
        self.rewindConfig = nil
        self.rewindImageExtractor = nil
        self.cutoffDate = nil
        Log.info("[DataAdapter] Rewind source disconnected", category: .app)
    }

    /// Initialize the adapter
    public func initialize() async throws {
        isInitialized = true

        // Cache the hidden tag ID
        if let hiddenTag = try? await database.getTag(name: "hidden") {
            cachedHiddenTagId = hiddenTag.id.value
            Log.debug("[DataAdapter] Cached hidden tag ID: \(hiddenTag.id.value)", category: .app)
        } else {
            Log.warning("[DataAdapter] Hidden tag not found in database", category: .app)
        }

        Log.info("[DataAdapter] Initialized with \(rewindConnection != nil ? "2" : "1") connection(s)", category: .app)
    }

    /// Shutdown the adapter
    public func shutdown() async {
        isInitialized = false
        cachedHiddenTagId = nil
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
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesInRangeWithFilters(from: startDate, to: endDate, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind if timestamp is before cutoff
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let frames = try queryFramesWithVideoInfo(from: startDate, to: effectiveEnd, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let frames = try queryFramesWithVideoInfo(from: retraceStart, to: endDate, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for date range - tries Retrace first, then Rewind
    private func getFramesInRangeWithFilters(from startDate: Date, to endDate: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            var retraceStart = startDate
            if let cutoff = cutoffDate {
                retraceStart = max(startDate, cutoff)
            }
            if retraceStart < endDate {
                let retraceFrames = try queryFramesInRangeWithFiltersOptimized(
                    from: retraceStart,
                    to: endDate,
                    limit: limit,
                    connection: retraceConnection,
                    config: retraceConfig,
                    filters: filters
                )
                allFrames.append(contentsOf: retraceFrames)
                remaining = limit - retraceFrames.count
            }
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        if remaining > 0, !excludeRewind, let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let rewindFrames = try queryFramesInRangeWithFiltersOptimized(
                from: startDate,
                to: effectiveEnd,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters
            )
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return allFrames
    }

    /// Get frames in a time range
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get most recent frames with video info
    public func getMostRecentFramesWithVideoInfo(limit: Int = 250, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getMostRecentFramesWithFilters(limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Retrace
        let retraceFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query - tries Retrace first, then Rewind to get full limit
    private func getMostRecentFramesWithFilters(limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            let retraceFrames = try queryMostRecentFramesWithFiltersOptimized(
                limit: limit,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining = limit - retraceFrames.count
            Log.debug("[Filter] Got \(retraceFrames.count) frames from Retrace, need \(remaining) more", category: .database)
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        // Also skip if the filter's startDate is after the cutoff date (no Rewind data exists after cutoff)
        let hasTagFilters = (filters.selectedTags != nil && !filters.selectedTags!.isEmpty) ||
                           filters.hiddenFilter == .onlyHidden
        let startDateAfterCutoff = cutoffDate != nil && filters.startDate != nil && filters.startDate! >= cutoffDate!
        if remaining > 0, !excludeRewind, !hasTagFilters, !startDateAfterCutoff, let rewind = rewindConnection, let config = rewindConfig {
            let rewindFrames = try queryMostRecentFramesWithFiltersOptimized(
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
            Log.debug("[Filter] Got \(rewindFrames.count) frames from Rewind", category: .database)
        } else if startDateAfterCutoff {
            Log.debug("[Filter] Skipping Rewind query - startDate \(filters.startDate!) is after cutoff \(cutoffDate!)", category: .database)
        }

        // Sort by timestamp descending (newest first)
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return allFrames
    }

    /// Get most recent frames
    public func getMostRecentFrames(limit: Int = 250, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info before a timestamp
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesBeforeWithFilters(timestamp: timestamp, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let frames = try queryFramesWithVideoInfoBefore(timestamp: effectiveTimestamp, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames before timestamp - tries Retrace first, then Rewind
    private func getFramesBeforeWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            let retraceFrames = try queryFramesBeforeWithFiltersOptimized(
                timestamp: timestamp,
                limit: limit,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining = limit - retraceFrames.count
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasTagFilters = (filters.selectedTags != nil && !filters.selectedTags!.isEmpty) ||
                           filters.hiddenFilter == .onlyHidden
        if remaining > 0, !excludeRewind, !hasTagFilters, let rewind = rewindConnection, let config = rewindConfig {
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let rewindFrames = try queryFramesBeforeWithFiltersOptimized(
                timestamp: effectiveTimestamp,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp descending (newest first)
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return allFrames
    }

    /// Get frames before a timestamp
    public func getFramesBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info after a timestamp
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesAfterWithFilters(timestamp: timestamp, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind (respecting cutoff)
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            let frames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames after timestamp - tries Retrace first, then Rewind
    private func getFramesAfterWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            let retraceFrames = try queryFramesAfterWithFiltersOptimized(
                timestamp: timestamp,
                limit: limit,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining = limit - retraceFrames.count
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasTagFilters = (filters.selectedTags != nil && !filters.selectedTags!.isEmpty) ||
                           filters.hiddenFilter == .onlyHidden
        if remaining > 0, !excludeRewind, !hasTagFilters, let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            let rewindFrames = try queryFramesAfterWithFiltersOptimized(
                timestamp: timestamp,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return allFrames
    }

    /// Get frames after a timestamp
    public func getFramesAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get a single frame by ID with video info
    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Try Retrace first (more likely for recent frames)
        if let frame = try queryFrameWithVideoInfoByID(id: id, connection: retraceConnection, config: retraceConfig) {
            return frame
        }

        // Try Rewind if available
        if let rewind = rewindConnection, let config = rewindConfig {
            return try queryFrameWithVideoInfoByID(id: id, connection: rewind, config: config)
        }

        return nil
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
    /// Get distinct app bundle IDs from the database
    /// Caller is responsible for resolving names (use AppNameResolver.shared.resolveAll)
    public func getDistinctAppBundleIDs() async throws -> [String] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        var bundleIDs: [String] = []

        // Try Rewind first (more historical data)
        if let rewind = rewindConnection {
            let queryStart = CFAbsoluteTimeGetCurrent()
            bundleIDs = try queryDistinctApps(connection: rewind)
            Log.debug("[DataAdapter] Rewind query took \(Int((CFAbsoluteTimeGetCurrent() - queryStart) * 1000))ms, found \(bundleIDs.count) bundle IDs", category: .database)
        }

        // If empty, try Retrace
        if bundleIDs.isEmpty {
            let queryStart = CFAbsoluteTimeGetCurrent()
            bundleIDs = try queryDistinctApps(connection: retraceConnection)
            Log.debug("[DataAdapter] Retrace query took \(Int((CFAbsoluteTimeGetCurrent() - queryStart) * 1000))ms, found \(bundleIDs.count) bundle IDs", category: .database)
        }

        Log.debug("[DataAdapter] getDistinctAppBundleIDs total: \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms", category: .database)
        return bundleIDs
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

        Log.info("[DataAdapter] Search started: query='\(query.text)', mode=\(query.mode), limit=\(query.limit), appFilter=\(query.filters.appBundleIDs ?? []), startDate=\(String(describing: query.filters.startDate)), endDate=\(String(describing: query.filters.endDate))", category: .app)

        let startTime = Date()
        var allResults: [SearchResult] = []
        var totalCount = 0

        // Search Retrace
        let retraceStart = Date()
        do {
            let retraceResults = try searchConnection(query: query, connection: retraceConnection, config: retraceConfig, source: .native)
            let retraceElapsed = Int(Date().timeIntervalSince(retraceStart) * 1000)
            Log.info("[DataAdapter] Retrace search completed in \(retraceElapsed)ms, found \(retraceResults.results.count) results", category: .app)
            allResults.append(contentsOf: retraceResults.results)
            totalCount += retraceResults.totalCount
        } catch {
            Log.warning("[DataAdapter] Retrace search failed: \(error)", category: .app)
        }

        // Search Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindStart = Date()
            do {
                var rewindResults = try searchConnection(query: query, connection: rewind, config: config, source: .rewind)
                let rewindElapsed = Int(Date().timeIntervalSince(rewindStart) * 1000)
                Log.info("[DataAdapter] Rewind search completed in \(rewindElapsed)ms, found \(rewindResults.results.count) results", category: .app)
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
    /// Public accessor for Rewind cutoff date (used to determine if data is from Rewind)
    public var rewindCutoffDate: Date? {
        cutoffDate
    }

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
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else { return [] }

        // Build WHERE clause based on filters
        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        var bindIndex = 3 // 1 and 2 are for timestamps

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                f.encodingStatus,
                \(processingStatusColumn),
                s.bundleID,
                s.windowName,
                s.browserUrl,
                v.path,
                v.frameRate,
                v.width,
                v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(effectiveEndDate, to: statement, at: 2)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Fast unfiltered query - uses subquery to limit before join
    private func queryMostRecentFramesWithVideoInfo(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus)
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

    /// Optimized filtered query - joins first to use bundleID index, then filters
    private func queryMostRecentFramesWithFiltersOptimized(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        var whereClauses: [String] = []
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    // Exclude hidden: We'll use NOT EXISTS clause below
                    break
                case .onlyHidden:
                    // Only show hidden: Set tags to only hidden tag
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    // Show all: Don't modify tag filter
                    break
                }
            }
        }

        // Window name filter - uses direct LIKE on segment.windowName (faster than FTS)
        let hasWindowNameFilter = filters.windowNameFilter != nil && !filters.windowNameFilter!.isEmpty

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        // Browser URL filter - partial string match
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let urlFilter = buildBrowserUrlFilterClause(urlPattern: browserUrlPattern)
            whereClauses.append(urlFilter.clause)
        }

        // Window name filter - direct LIKE on segment.windowName (much faster than FTS)
        if hasWindowNameFilter {
            whereClauses.append("s.windowName LIKE ?")
        }

        // Date range filter
        if filters.startDate != nil {
            whereClauses.append("f.createdAt >= ?")
        }
        if filters.endDate != nil {
            whereClauses.append("f.createdAt <= ?")
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        Log.debug("[Filter] ====== QUERY DEBUG START ======", category: .database)
        Log.debug("[Filter] Query SQL:\n\(sql)", category: .database)
        Log.debug("[Filter] Apps filter: \(filters.selectedApps ?? []), mode: \(filters.appFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Tags to filter: \(tagsToFilter), mode: \(tagFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Hidden filter: \(filters.hiddenFilter.rawValue), cachedHiddenTagId: \(String(describing: cachedHiddenTagId))", category: .database)
        Log.debug("[Filter] Window name filter: \(filters.windowNameFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Browser URL filter: \(filters.browserUrlFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Date range: \(String(describing: filters.startDate)) - \(String(describing: filters.endDate))", category: .database)

        let statement: OpaquePointer?
        do {
            statement = try connection.prepare(sql: sql)
        } catch {
            Log.error("[Filter] Failed to prepare SQL statement: \(error)", category: .database)
            if let db = connection.getConnection(), let errMsg = sqlite3_errmsg(db) {
                Log.error("[Filter] SQLite error: \(String(cString: errMsg))", category: .database)
            }
            return []
        }
        guard let stmt = statement else {
            Log.error("[Filter] Statement is nil after prepare!", category: .database)
            return []
        }
        defer { connection.finalize(stmt) }

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                Log.debug("[Filter] Binding tagId \(tagId) at index \(bindIndex + index)", category: .database)
                sqlite3_bind_int64(stmt, Int32(bindIndex + index), tagId)
            }
            bindIndex += tagsToFilter.count
        }

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                Log.debug("[Filter] Binding app '\(app)' at index \(bindIndex + index)", category: .database)
                sqlite3_bind_text(stmt, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind browser URL pattern
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let pattern = "%\(browserUrlPattern)%"
            Log.debug("[Filter] Binding browser URL pattern '\(pattern)' at index \(bindIndex)", category: .database)
            sqlite3_bind_text(stmt, Int32(bindIndex), (pattern as NSString).utf8String, -1, nil)
            bindIndex += 1
        }

        // Bind window name pattern (LIKE query on segment.windowName)
        if hasWindowNameFilter, let windowName = filters.windowNameFilter {
            let pattern = "%\(windowName)%"
            Log.debug("[Filter] Binding window name pattern '\(pattern)' at index \(bindIndex)", category: .database)
            sqlite3_bind_text(stmt, Int32(bindIndex), (pattern as NSString).utf8String, -1, nil)
            bindIndex += 1
        }

        // Bind date range
        if let startDate = filters.startDate {
            Log.debug("[Filter] Binding startDate at index \(bindIndex)", category: .database)
            config.bindDate(startDate, to: stmt, at: Int32(bindIndex))
            bindIndex += 1
        }
        if let endDate = filters.endDate {
            Log.debug("[Filter] Binding endDate at index \(bindIndex)", category: .database)
            config.bindDate(endDate, to: stmt, at: Int32(bindIndex))
            bindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                Log.debug("[Filter] Binding exclude tagId \(tagId) at index \(bindIndex + index)", category: .database)
                sqlite3_bind_int64(stmt, Int32(bindIndex + index), tagId)
            }
            bindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            Log.debug("[Filter] Binding hiddenTagId \(hiddenTagId) at index \(bindIndex)", category: .database)
            sqlite3_bind_int64(stmt, Int32(bindIndex), hiddenTagId)
            bindIndex += 1
        }

        // Bind limit
        Log.debug("[Filter] Binding limit \(limit) at index \(bindIndex)", category: .database)
        sqlite3_bind_int(stmt, Int32(bindIndex), Int32(limit))
        Log.debug("[Filter] ====== QUERY DEBUG END ======", category: .database)

        var frames: [FrameWithVideoInfo] = []
        var stepCount = 0
        var stepResult = sqlite3_step(stmt)

        while stepResult == SQLITE_ROW {
            stepCount += 1
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: stmt, config: config) {
                frames.append(frameWithVideo)
            }
            stepResult = sqlite3_step(stmt)
        }

        if stepResult != SQLITE_DONE {
            Log.error("[Filter] sqlite3_step error code: \(stepResult)", category: .database)
        }

        Log.debug("[Filter] Query returned \(frames.count) frames (stepped \(stepCount) times)", category: .database)

        return frames
    }

    /// Optimized filtered query for frames before timestamp - joins first to use bundleID index
    private func queryFramesBeforeWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        var whereClauses = ["f.createdAt < ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    // Exclude hidden: We'll use NOT EXISTS clause below
                    break
                case .onlyHidden:
                    // Only show hidden: Set tags to only hidden tag
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    // Show all: Don't modify tag filter
                    break
                }
            }
        }

        // Window name filter - uses direct LIKE on segment.windowName (faster than FTS)
        let hasWindowNameFilter = filters.windowNameFilter != nil && !filters.windowNameFilter!.isEmpty

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                // Update bindIndex to account for tag parameters in CTE
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamp (after tag IDs in CTE, if any)
        bindIndex += 1

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        // Browser URL filter - partial string match
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let urlFilter = buildBrowserUrlFilterClause(urlPattern: browserUrlPattern)
            whereClauses.append(urlFilter.clause)
        }

        // Window name filter - direct LIKE on segment.windowName (much faster than FTS)
        if hasWindowNameFilter {
            whereClauses.append("s.windowName LIKE ?")
        }

        // Date range filter - additional constraints beyond the timestamp
        if filters.startDate != nil {
            whereClauses.append("f.createdAt >= ?")
        }
        if filters.endDate != nil {
            whereClauses.append("f.createdAt <= ?")
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamp
        config.bindDate(effectiveTimestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        // Bind browser URL pattern
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let pattern = "%\(browserUrlPattern)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind window name pattern (LIKE query on segment.windowName)
        if hasWindowNameFilter, let windowName = filters.windowNameFilter {
            let pattern = "%\(windowName)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind date range
        if let startDate = filters.startDate {
            config.bindDate(startDate, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }
        if let endDate = filters.endDate {
            config.bindDate(endDate, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for frames after timestamp - joins first to use bundleID index
    private func queryFramesAfterWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        var whereClauses = ["f.createdAt > ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    break
                case .onlyHidden:
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    break
                }
            }
        }

        // Window name filter - uses direct LIKE on segment.windowName (faster than FTS)
        let hasWindowNameFilter = filters.windowNameFilter != nil && !filters.windowNameFilter!.isEmpty

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamp (after tag IDs in CTE, if any)
        bindIndex += 1

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        // Browser URL filter - partial string match
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let urlFilter = buildBrowserUrlFilterClause(urlPattern: browserUrlPattern)
            whereClauses.append(urlFilter.clause)
        }

        // Window name filter - direct LIKE on segment.windowName (much faster than FTS)
        if hasWindowNameFilter {
            whereClauses.append("s.windowName LIKE ?")
        }

        // Date range filter - additional constraints beyond the timestamp
        if filters.startDate != nil {
            whereClauses.append("f.createdAt >= ?")
        }
        if filters.endDate != nil {
            whereClauses.append("f.createdAt <= ?")
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamp
        config.bindDate(timestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        // Bind browser URL pattern
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let pattern = "%\(browserUrlPattern)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind window name pattern (LIKE query on segment.windowName)
        if hasWindowNameFilter, let windowName = filters.windowNameFilter {
            let pattern = "%\(windowName)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind date range
        if let startDate = filters.startDate {
            config.bindDate(startDate, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }
        if let endDate = filters.endDate {
            config.bindDate(endDate, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for date range - joins first to use bundleID index
    private func queryFramesInRangeWithFiltersOptimized(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria
    ) throws -> [FrameWithVideoInfo] {
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else { return [] }

        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        var tagsToFilter = filters.selectedTags ?? Set<Int64>()

        // Apply hidden filter logic
        if let hiddenTagId = cachedHiddenTagId {
            switch filters.hiddenFilter {
            case .hide:
                break
            case .onlyHidden:
                tagsToFilter = [hiddenTagId]
            case .showAll:
                break
            }
        }

        // Window name filter - uses direct LIKE on segment.windowName (faster than FTS)
        let hasWindowNameFilter = filters.windowNameFilter != nil && !filters.windowNameFilter!.isEmpty

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamps (after tag IDs in CTE, if any)
        bindIndex += 2  // For startDate and endDate

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        // Browser URL filter - partial string match
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let urlFilter = buildBrowserUrlFilterClause(urlPattern: browserUrlPattern)
            whereClauses.append(urlFilter.clause)
        }

        // Window name filter - direct LIKE on segment.windowName (much faster than FTS)
        if hasWindowNameFilter {
            whereClauses.append("s.windowName LIKE ?")
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Skip for Rewind database - it doesn't have segment_tag table
        if filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId, config.source != .rewind {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamps
        config.bindDate(startDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1
        config.bindDate(effectiveEndDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        // Bind browser URL pattern
        if let browserUrlPattern = filters.browserUrlFilter, !browserUrlPattern.isEmpty {
            let pattern = "%\(browserUrlPattern)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind window name pattern (LIKE query on segment.windowName)
        if hasWindowNameFilter, let windowName = filters.windowNameFilter {
            let pattern = "%\(windowName)%"
            sqlite3_bind_text(statement, Int32(currentBindIndex), (pattern as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Skip for Rewind database - it doesn't have segment_tag table
        if filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId, config.source != .rewind {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

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
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        // Build WHERE clause based on filters
        var whereClauses = ["createdAt < ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus)
                FROM frame
                WHERE \(whereClause)
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        // Bind timestamp
        config.bindDate(effectiveTimestamp, to: statement, at: 1)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

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
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        // Build WHERE clause based on filters
        var whereClauses = ["createdAt > ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus)
                FROM frame
                WHERE \(whereClause)
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        // Bind timestamp
        config.bindDate(timestamp, to: statement, at: 1)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFrameWithVideoInfoByID(
        id: FrameID,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameWithVideoInfo? {
        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.id = ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return nil }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, id.value)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        return try parseFrameWithVideoInfo(statement: statement, config: config)
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
        // DEBUG: First check what docid is linked to this frame
        let debugSQL = """
            SELECT ds.docid, ds.frameId, LENGTH(COALESCE(sc.c0, '')) as textLen
            FROM doc_segment ds
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE ds.frameId = ?;
            """
        if let debugStmt = try? connection.prepare(sql: debugSQL) {
            sqlite3_bind_int64(debugStmt, 1, frameID.value)
            if sqlite3_step(debugStmt) == SQLITE_ROW {
                let docid = sqlite3_column_int64(debugStmt, 0)
                let dsFrameId = sqlite3_column_int64(debugStmt, 1)
                let textLen = sqlite3_column_int(debugStmt, 2)
                Log.debug("[DB-DEBUG] For frameID=\(frameID.value): doc_segment has docid=\(docid), frameId=\(dsFrameId), textLen=\(textLen)", category: .database)
            } else {
                Log.debug("[DB-DEBUG] For frameID=\(frameID.value): NO doc_segment found!", category: .database)
            }
            connection.finalize(debugStmt)
        }

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
                (COALESCE(sc.c0, '') || COALESCE(sc.c1, '')) as fullText,
                n.frameId
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, frameID.value)

        // Reset parse debug counter for new frame
        DataAdapter.parseDebugCounter = 0

        var nodes: [OCRNodeWithText] = []
        var isFirstNode = true
        while sqlite3_step(statement) == SQLITE_ROW {
            // DEBUG: Log first row's fullText to see what we're getting
            if isFirstNode {
                if let fullTextPtr = sqlite3_column_text(statement, 8) {
                    let fullText = String(cString: fullTextPtr)
                    Log.debug("[DB-DEBUG] frameID=\(frameID.value) fullText preview: '\(fullText.prefix(100))...'", category: .database)
                }
                isFirstNode = false
            }
            if let node = parseOCRNodeFromRow(statement: statement) {
                nodes.append(node)
            }
        }

        Log.debug("[DB-DEBUG] frameID=\(frameID.value) returned \(nodes.count) nodes", category: .database)
        return nodes
    }

    private func queryDistinctApps(connection: DatabaseConnection) throws -> [String] {
        let sql = """
            SELECT DISTINCT bundleID
            FROM segment
            WHERE bundleID IS NOT NULL AND bundleID != ''
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
        let relevanceLimit = 50

        Log.info("[DataAdapter.searchRelevant] Starting: ftsQuery='\(ftsQuery)', source=\(source), appFilter=\(query.filters.appBundleIDs ?? []), windowNameFilter=\(query.filters.windowNameFilter ?? "nil"), browserUrlFilter=\(query.filters.browserUrlFilter ?? "nil")", category: .app)

        // Build WHERE conditions for the outer query (filters applied after FTS subquery)
        var outerWhereConditions: [String] = []
        var outerBindValues: [Any] = []

        if let cutoffDate = config.cutoffDate {
            outerWhereConditions.append("f.createdAt < ?")
            outerBindValues.append(config.formatDate(cutoffDate))
        }

        if let startDate = query.filters.startDate {
            outerWhereConditions.append("f.createdAt >= ?")
            outerBindValues.append(config.formatDate(startDate))
        }
        if let endDate = query.filters.endDate {
            outerWhereConditions.append("f.createdAt <= ?")
            outerBindValues.append(config.formatDate(endDate))
        }

        // App include filter
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let appPlaceholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            outerWhereConditions.append("s.bundleID IN (\(appPlaceholders))")
            outerBindValues.append(contentsOf: appBundleIDs)
        }

        // App exclude filter
        if let excludedAppBundleIDs = query.filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            let appPlaceholders = excludedAppBundleIDs.map { _ in "?" }.joined(separator: ", ")
            outerWhereConditions.append("s.bundleID NOT IN (\(appPlaceholders))")
            outerBindValues.append(contentsOf: excludedAppBundleIDs)
        }

        // Window name filter (partial match)
        if let windowNameFilter = query.filters.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowNameFilter.isEmpty {
            outerWhereConditions.append("s.windowName LIKE ?")
            outerBindValues.append("%\(windowNameFilter)%")
        }

        // Browser URL filter (partial match)
        if let browserUrlFilter = query.filters.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !browserUrlFilter.isEmpty {
            outerWhereConditions.append("s.browserUrl LIKE ?")
            outerBindValues.append("%\(browserUrlFilter)%")
        }

        // Tag include filter - use INNER JOIN (more efficient than EXISTS subquery)
        // Note: Skip tag filters for Rewind database (it doesn't have segment_tag table)
        // When no tags selected, tagJoin is empty and no join happens
        let isRewind = source == .rewind
        let hasTagIncludeFilter = !isRewind && query.filters.selectedTagIds != nil && !query.filters.selectedTagIds!.isEmpty
        var tagJoinBindValues: [Int64] = []
        let tagJoin: String
        if !isRewind, let tagIds = query.filters.selectedTagIds, !tagIds.isEmpty {
            let tagPlaceholders = tagIds.map { _ in "?" }.joined(separator: ", ")
            tagJoin = "INNER JOIN segment_tag st_include ON f.segmentId = st_include.segmentId AND st_include.tagId IN (\(tagPlaceholders))"
            tagJoinBindValues = tagIds
        } else {
            tagJoin = ""
        }

        // Tag exclude filter - use NOT EXISTS (skip for Rewind)
        if !isRewind, let excludedTagIds = query.filters.excludedTagIds, !excludedTagIds.isEmpty {
            let tagPlaceholders = excludedTagIds.map { _ in "?" }.joined(separator: ", ")
            outerWhereConditions.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
            outerBindValues.append(contentsOf: excludedTagIds)
        }

        // Hidden filter - skip for Rewind database (no segment_tag table)
        if !isRewind {
            switch query.filters.hiddenFilter {
            case .hide:
                // Exclude hidden segments
                if let hiddenTagId = cachedHiddenTagId {
                    outerWhereConditions.append("""
                        NOT EXISTS (
                            SELECT 1 FROM segment_tag st_hidden
                            WHERE st_hidden.segmentId = f.segmentId
                            AND st_hidden.tagId = ?
                        )
                        """)
                    outerBindValues.append(hiddenTagId)
                }
            case .onlyHidden:
                // Only show hidden segments
                if let hiddenTagId = cachedHiddenTagId {
                    outerWhereConditions.append("""
                        EXISTS (
                            SELECT 1 FROM segment_tag st_hidden
                            WHERE st_hidden.segmentId = f.segmentId
                            AND st_hidden.tagId = ?
                        )
                        """)
                    outerBindValues.append(hiddenTagId)
                }
            case .showAll:
                // No filter needed - show both hidden and visible
                break
            }
        }

        let outerWhereClause = outerWhereConditions.isEmpty ? "" : "WHERE " + outerWhereConditions.joined(separator: " AND ")

        // Subquery approach: FTS with bm25 FIRST (limited), then join and filter
        // No snippet() - it's expensive and not needed (we get text from OCR nodes)
        // Tag include uses INNER JOIN (more efficient than EXISTS in WHERE clause)
        let sql = """
            SELECT
                fts.docid,
                f.id as frame_id,
                f.createdAt as timestamp,
                s.id as segment_id,
                s.bundleID as app_bundle_id,
                s.windowName as window_title,
                s.browserUrl as browser_url,
                f.videoId as video_id,
                f.videoFrameIndex as frame_index,
                fts.rank
            FROM (
                SELECT
                    rowid as docid,
                    bm25(searchRanking) as rank
                FROM searchRanking
                WHERE searchRanking MATCH ?
                ORDER BY bm25(searchRanking)
                LIMIT ?
            ) fts
            JOIN doc_segment ds ON fts.docid = ds.docid
            JOIN frame f ON ds.frameId = f.id
            JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            \(outerWhereClause)
            ORDER BY fts.rank
            LIMIT ? OFFSET ?
        """

        Log.info("[DataAdapter.searchRelevant] SQL: \(sql.replacingOccurrences(of: "\n", with: " "))", category: .app)
        Log.info("[DataAdapter.searchRelevant] Binds: ftsQuery='\(ftsQuery)', tagJoinValues=\(tagJoinBindValues), outerFilters=\(outerBindValues), limit=\(relevanceLimit), offset=\(query.offset)", category: .app)

        guard let statement = try? connection.prepare(sql: sql) else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1

        // Bind FTS query
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        // Bind inner LIMIT (for FTS subquery) - fetch more to account for filtering
        let innerLimit = (outerWhereConditions.isEmpty && tagJoinBindValues.isEmpty) ? relevanceLimit : relevanceLimit * 10
        sqlite3_bind_int(statement, bindIndex, Int32(innerLimit))
        bindIndex += 1

        // Bind tag INNER JOIN values (these come before WHERE clause values)
        for tagId in tagJoinBindValues {
            sqlite3_bind_int64(statement, bindIndex, tagId)
            bindIndex += 1
        }

        // Bind outer WHERE values
        for value in outerBindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(statement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        // Bind outer LIMIT and OFFSET
        sqlite3_bind_int(statement, bindIndex, Int32(relevanceLimit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(query.offset))

        var results: [SearchResult] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let frameId = sqlite3_column_int64(statement, 1)
            let segmentId = sqlite3_column_int64(statement, 3)
            let appBundleID = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let browserUrl = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let videoId = sqlite3_column_int64(statement, 7)
            let frameIndex = Int(sqlite3_column_int(statement, 8))
            let rank = sqlite3_column_double(statement, 9)

            let appName = appBundleID?.components(separatedBy: ".").last
            let timestamp = config.parseDate(from: statement, column: 2) ?? Date()

            let result = SearchResult(
                id: FrameID(value: frameId),
                timestamp: timestamp,
                snippet: "", // Snippet not needed - OCR nodes provide text
                matchedText: query.text,
                relevanceScore: abs(rank) / (1.0 + abs(rank)),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: browserUrl,
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
        Log.info("[DataAdapter.searchRelevant] Completed in \(totalElapsed)ms, found \(results.count) results", category: .app)

        return SearchResults(query: query, results: results, totalCount: results.count, searchTimeMs: totalElapsed)
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

        // Build WHERE conditions for outer query
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

        // App include filter
        let hasAppFilter = query.filters.appBundleIDs != nil && !query.filters.appBundleIDs!.isEmpty
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            if appBundleIDs.count == 1 {
                // Single app: use = for better query optimization
                whereConditions.append("s.bundleID = ?")
                bindValues.append(appBundleIDs[0])
            } else {
                // Multiple apps: use IN
                let placeholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
                whereConditions.append("s.bundleID IN (\(placeholders))")
                bindValues.append(contentsOf: appBundleIDs)
            }
        }

        // App exclude filter
        if let excludedAppBundleIDs = query.filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            if excludedAppBundleIDs.count == 1 {
                whereConditions.append("s.bundleID != ?")
                bindValues.append(excludedAppBundleIDs[0])
            } else {
                let placeholders = excludedAppBundleIDs.map { _ in "?" }.joined(separator: ", ")
                whereConditions.append("s.bundleID NOT IN (\(placeholders))")
                bindValues.append(contentsOf: excludedAppBundleIDs)
            }
        }

        // Window name filter (partial match)
        if let windowNameFilter = query.filters.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowNameFilter.isEmpty {
            whereConditions.append("s.windowName LIKE ?")
            bindValues.append("%\(windowNameFilter)%")
        }

        // Browser URL filter (partial match)
        if let browserUrlFilter = query.filters.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !browserUrlFilter.isEmpty {
            whereConditions.append("s.browserUrl LIKE ?")
            bindValues.append("%\(browserUrlFilter)%")
        }

        // Tag include filter - use INNER JOIN (more efficient than EXISTS subquery)
        // Note: Skip tag filters for Rewind database (it doesn't have segment_tag table)
        // When no tags selected, tagJoin is empty and no join happens
        let isRewind = source == .rewind
        let hasTagIncludeFilter = !isRewind && query.filters.selectedTagIds != nil && !query.filters.selectedTagIds!.isEmpty
        var tagJoinBindValues: [Int64] = []
        let tagJoin: String
        if !isRewind, let tagIds = query.filters.selectedTagIds, !tagIds.isEmpty {
            let tagPlaceholders = tagIds.map { _ in "?" }.joined(separator: ", ")
            tagJoin = "INNER JOIN segment_tag st_include ON f.segmentId = st_include.segmentId AND st_include.tagId IN (\(tagPlaceholders))"
            tagJoinBindValues = tagIds
        } else {
            tagJoin = ""
        }

        // Tag exclude filter - use NOT EXISTS (skip for Rewind)
        if !isRewind, let excludedTagIds = query.filters.excludedTagIds, !excludedTagIds.isEmpty {
            let tagPlaceholders = excludedTagIds.map { _ in "?" }.joined(separator: ", ")
            whereConditions.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
            bindValues.append(contentsOf: excludedTagIds)
        }

        // Hidden filter - skip for Rewind database (no segment_tag table)
        if !isRewind {
            switch query.filters.hiddenFilter {
            case .hide:
                // Exclude hidden segments
                if let hiddenTagId = cachedHiddenTagId {
                    whereConditions.append("""
                        NOT EXISTS (
                            SELECT 1 FROM segment_tag st_hidden
                            WHERE st_hidden.segmentId = f.segmentId
                            AND st_hidden.tagId = ?
                        )
                        """)
                    bindValues.append(hiddenTagId)
                }
            case .onlyHidden:
                // Only show hidden segments
                if let hiddenTagId = cachedHiddenTagId {
                    whereConditions.append("""
                        EXISTS (
                            SELECT 1 FROM segment_tag st_hidden
                            WHERE st_hidden.segmentId = f.segmentId
                            AND st_hidden.tagId = ?
                        )
                        """)
                    bindValues.append(hiddenTagId)
                }
            case .showAll:
                // No filter needed - show both hidden and visible
                break
            }
        }

        // Determine if we need the segment table join (for app filter or tag/hidden filters)
        let hasTagFilters = hasTagIncludeFilter ||
            (!isRewind && query.filters.excludedTagIds != nil && !query.filters.excludedTagIds!.isEmpty) ||
            (!isRewind && query.filters.hiddenFilter != .showAll)
        let hasMetadataFilters =
            (query.filters.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ||
            (query.filters.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        let whereClause = whereConditions.isEmpty ? "" : "WHERE " + whereConditions.joined(separator: " AND ")

        // CTE MATERIALIZED approach: Force SQLite to compute FTS results first
        // Without MATERIALIZED, SQLite may inline the CTE and optimize it poorly
        // Tag include uses INNER JOIN (more efficient than EXISTS in WHERE clause)
        // Determine sort order
        let sortOrderClause = query.sortOrder == .newestFirst ? "DESC" : "ASC"

        let sql: String
        if hasAppFilter || hasTagFilters || hasMetadataFilters {
            // With app/tag filter: CTE MATERIALIZED for FTS first, then join all tables and filter
            sql = """
                WITH fts_matches AS MATERIALIZED (
                    SELECT rowid as docid FROM searchRanking WHERE searchRanking MATCH ?
                )
                SELECT
                    f.id as frame_id,
                    f.createdAt as timestamp,
                    f.segmentId as segment_id,
                    f.videoId as video_id,
                    f.videoFrameIndex as frame_index
                FROM fts_matches fts
                JOIN doc_segment ds ON fts.docid = ds.docid
                JOIN frame f ON ds.frameId = f.id
                JOIN segment s ON f.segmentId = s.id
                \(tagJoin)
                \(whereClause)
                ORDER BY f.createdAt \(sortOrderClause)
                LIMIT ? OFFSET ?
            """
        } else {
            // No app/tag filter: use IN subquery with limit (faster for no-filter case)
            let ftsLimit = query.limit + query.offset + 200
            let filterClause = whereConditions.isEmpty ? "" : "AND " + whereConditions.joined(separator: " AND ")
            sql = """
                SELECT
                    f.id as frame_id,
                    f.createdAt as timestamp,
                    f.segmentId as segment_id,
                    f.videoId as video_id,
                    f.videoFrameIndex as frame_index
                FROM doc_segment ds
                JOIN frame f ON ds.frameId = f.id
                WHERE ds.docid IN (
                    SELECT rowid FROM searchRanking WHERE searchRanking MATCH ? ORDER BY rowid DESC LIMIT \(ftsLimit)
                ) \(filterClause)
                ORDER BY f.createdAt \(sortOrderClause)
                LIMIT ? OFFSET ?
            """
        }

        Log.info("[DataAdapter.searchAll] SQL: \(sql.replacingOccurrences(of: "\n", with: " "))", category: .app)
        Log.info("[DataAdapter.searchAll] Binds: ftsQuery='\(ftsQuery)', tagJoinValues=\(tagJoinBindValues), bindValues=\(bindValues), limit=\(query.limit), offset=\(query.offset)", category: .app)

        guard let statement = try? connection.prepare(sql: sql) else {
            Log.error("[DataAdapter.searchAll] Failed to prepare SQL statement", category: .app)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1

        // Bind FTS query
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        // Bind tag INNER JOIN values (these come before WHERE clause values)
        for tagId in tagJoinBindValues {
            sqlite3_bind_int64(statement, bindIndex, tagId)
            bindIndex += 1
        }

        // Bind WHERE clause values (cutoff, date filters, app filter, exclude tags, hidden)
        for value in bindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(statement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        // Bind LIMIT and OFFSET
        sqlite3_bind_int(statement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(query.offset))

        var frameResults: [(frameId: Int64, timestamp: Date, segmentId: Int64, videoId: Int64, frameIndex: Int)] = []

        let stepStartTime = Date()
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameId = sqlite3_column_int64(statement, 0)
            let timestamp = config.parseDate(from: statement, column: 1) ?? Date()
            let segmentId = sqlite3_column_int64(statement, 2)
            let videoId = sqlite3_column_int64(statement, 3)
            let frameIndex = Int(sqlite3_column_int(statement, 4))
            frameResults.append((frameId: frameId, timestamp: timestamp, segmentId: segmentId, videoId: videoId, frameIndex: frameIndex))
        }
        let queryElapsed = Int(Date().timeIntervalSince(stepStartTime) * 1000)
        Log.info("[DataAdapter.searchAll] SQL executed in \(queryElapsed)ms, found \(frameResults.count) frames, source: \(source)", category: .app)

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
            let browserUrl = segmentMeta?.browserUrl
            let appName = appBundleID?.components(separatedBy: ".").last

            let result = SearchResult(
                id: FrameID(value: frame.frameId),
                timestamp: frame.timestamp,
                snippet: query.text, // Use query as snippet - OCR text loaded separately for highlighting
                matchedText: query.text,
                relevanceScore: 0.5,
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: browserUrl,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: frame.segmentId),
                videoID: VideoSegmentID(value: frame.videoId),
                frameIndex: frame.frameIndex,
                source: source
            )

            results.append(result)
        }

        let totalCount = getSearchTotalCount(ftsQuery: ftsQuery, connection: connection)

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        return SearchResults(query: query, results: results, totalCount: totalCount, searchTimeMs: elapsed)
    }

    private func fetchSegmentMetadata(segmentIds: [Int64], connection: DatabaseConnection) -> [Int64: (bundleID: String?, windowName: String?, browserUrl: String?)] {
        guard !segmentIds.isEmpty else { return [:] }

        let placeholders = segmentIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, bundleID, windowName, browserUrl FROM segment WHERE id IN (\(placeholders))"

        guard let statement = try? connection.prepare(sql: sql) else { return [:] }
        defer { connection.finalize(statement) }

        for (index, segmentId) in segmentIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), segmentId)
        }

        var metadata: [Int64: (bundleID: String?, windowName: String?, browserUrl: String?)] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let browserUrl = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            metadata[id] = (bundleID: bundleID, windowName: windowName, browserUrl: browserUrl)
        }

        return metadata
    }

    private func buildFTSQuery(_ text: String) -> String {
        var parts: [String] = []
        var current = ""
        var inQuotes = false

        // Tokenize while preserving quoted phrases
        for char in text {
            if char == "\"" {
                if inQuotes {
                    // End of quoted phrase
                    if !current.isEmpty {
                        // Phrase search: wrap in quotes, no prefix matching
                        let escaped = current
                            .replacingOccurrences(of: "*", with: "")
                            .replacingOccurrences(of: ":", with: "")
                        parts.append("\"\(escaped)\"")
                    }
                    current = ""
                    inQuotes = false
                } else {
                    // Start of quoted phrase - save any pending word first
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        let word = current.trimmingCharacters(in: .whitespaces)
                        let escaped = word
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "*", with: "")
                            .replacingOccurrences(of: ":", with: "")
                        parts.append("\"\(escaped)\"*")
                    }
                    current = ""
                    inQuotes = true
                }
            } else if char.isWhitespace && !inQuotes {
                // Word boundary outside quotes
                if !current.isEmpty {
                    let escaped = current
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "*", with: "")
                        .replacingOccurrences(of: ":", with: "")
                    parts.append("\"\(escaped)\"*")
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        // Handle remaining content
        if !current.isEmpty {
            let escaped = current
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: ":", with: "")
            if inQuotes {
                // Unclosed quote - treat as phrase anyway
                parts.append("\"\(escaped)\"")
            } else {
                parts.append("\"\(escaped)\"*")
            }
        }

        return parts.joined(separator: " ")
    }

    /// Build SQL clause for app filtering (IN or NOT IN based on filter mode)
    /// Returns the SQL clause like "s.bundleID IN (?, ?, ?)" or "s.bundleID NOT IN (?, ?, ?)"
    private func buildAppFilterClause(apps: Set<String>, mode: AppFilterMode, tableAlias: String = "s") -> String {
        let placeholders = apps.map { _ in "?" }.joined(separator: ", ")
        let operator_ = mode == .include ? "IN" : "NOT IN"
        return "\(tableAlias).bundleID \(operator_) (\(placeholders))"
    }

    /// Build SQL clause for browser URL partial string matching
    /// Returns the SQL clause like "s.browserUrl LIKE ?" and the pattern to bind
    private func buildBrowserUrlFilterClause(urlPattern: String, tableAlias: String = "s") -> (clause: String, pattern: String) {
        // Use LIKE with wildcards for partial matching
        let pattern = "%\(urlPattern)%"
        return (clause: "\(tableAlias).browserUrl LIKE ?", pattern: pattern)
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
        let processingStatus = Int(sqlite3_column_int(statement, 6))

        let bundleID = getTextOrNil(statement, 7) ?? ""
        let windowName = getTextOrNil(statement, 8)
        let browserUrl = getTextOrNil(statement, 9)

        let videoPath = getTextOrNil(statement, 10)
        let frameRate = sqlite3_column_type(statement, 11) != SQLITE_NULL ? sqlite3_column_double(statement, 11) : nil
        let width = sqlite3_column_type(statement, 12) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 12)) : nil
        let height = sqlite3_column_type(statement, 13) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 13)) : nil

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

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo, processingStatus: processingStatus)
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

    private static var parseDebugCounter = 0

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

        // Column 9: frameId for debugging
        let frameId = sqlite3_column_int64(statement, 9)

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

        // DEBUG: Log first 5 nodes to see offset/length details (commented out to reduce log noise)
        // DataAdapter.parseDebugCounter += 1
        // if DataAdapter.parseDebugCounter <= 5 {
        //     Log.debug("[PARSE-DEBUG] Node \(DataAdapter.parseDebugCounter): id=\(id), offset=\(textOffset), length=\(textLength), fullTextLen=\(fullText.count), extracted='\(text.prefix(30))'", category: .database)
        // } else if DataAdapter.parseDebugCounter == 6 {
        //     Log.debug("[PARSE-DEBUG] (suppressing further logs...)", category: .database)
        //     DataAdapter.parseDebugCounter = 100 // prevent re-printing "suppressing" message
        // }

        return OCRNodeWithText(
            id: id,
            frameId: frameId,
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

    // MARK: - Combined Statistics (Retrace + Rewind)

    /// Get distinct dates that have frames from both Retrace and Rewind sources
    /// Returns dates sorted in descending order (newest first)
    public func getDistinctDates() throws -> [Date] {
        var allDates = Set<Date>()
        let calendar = Calendar.current

        // Get dates from Retrace
        let retraceDates = try queryDistinctDates(connection: retraceConnection)
        for date in retraceDates {
            allDates.insert(calendar.startOfDay(for: date))
        }

        // Get dates from Rewind if connected
        if let rewind = rewindConnection {
            let rewindDates = try queryDistinctDates(connection: rewind)
            for date in rewindDates {
                allDates.insert(calendar.startOfDay(for: date))
            }
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    /// Query distinct dates from a specific connection
    private func queryDistinctDates(connection: DatabaseConnection) throws -> [Date] {
        let sql = """
            SELECT MIN(createdAt) as dayTimestamp
            FROM frame
            GROUP BY date(createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY dayTimestamp DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_int64(statement, 0)
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
            dates.append(date)
        }

        return dates
    }

    /// Check if Rewind source is connected
    public var isRewindConnected: Bool {
        rewindConnection != nil
    }

    /// Get distinct dates from Rewind only (for parallel loading)
    public func getRewindDistinctDates() throws -> [Date] {
        guard let rewind = rewindConnection else { return [] }
        return try queryDistinctDates(connection: rewind)
    }

    /// Get Rewind storage root path for storage calculations (returns nil if Rewind not connected)
    public var rewindStorageRootPath: String? {
        guard rewindConnection != nil else { return nil }
        return AppPaths.expandedRewindStorageRoot
    }

    // MARK: - Calendar Hours Query

    /// Get distinct hours for a specific date that have frames
    /// Queries both databases and merges results to show all available hours
    public func getDistinctHoursForDate(_ date: Date) throws -> [Date] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var allHours = Set<Date>()

        // Query Retrace database
        let retraceHours = try queryDistinctHoursRetrace(
            connection: retraceConnection,
            startOfDay: startOfDay,
            endOfDay: endOfDay
        )
        allHours.formUnion(retraceHours)

        // Query Rewind database if connected
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindHours = try queryDistinctHoursRewind(
                connection: rewind,
                config: config,
                startOfDay: startOfDay,
                endOfDay: endOfDay
            )
            allHours.formUnion(rewindHours)
        }

        // Return sorted by time (earliest first)
        return Array(allHours).sorted()
    }

    /// Query distinct hours from Retrace database (INTEGER timestamps in milliseconds)
    /// Returns the actual first frame timestamp for each hour (not normalized to :00:00)
    /// so that navigation can find frames around that time
    private func queryDistinctHoursRetrace(
        connection: DatabaseConnection,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)

        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY strftime('%H', createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY hourTimestamp ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)

        var hours: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestampMs = sqlite3_column_int64(statement, 0)
            // Return actual timestamp (not normalized) so navigation can find frames
            let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
            hours.append(timestamp)
        }

        return hours
    }

    /// Query distinct hours from Rewind database (TEXT ISO8601 timestamps)
    /// Returns the actual first frame timestamp for each hour (not normalized to :00:00)
    /// so that navigation can find frames around that time
    private func queryDistinctHoursRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        guard let formatter = config.dateFormatter else {
            return []
        }

        let startISO = formatter.string(from: startOfDay)
        let endISO = formatter.string(from: endOfDay)

        // Rewind stores TEXT timestamps like '2025-12-18T22:00:02.655'
        // Extract hour using substr (faster than strftime on TEXT)
        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY substr(createdAt, 12, 2)
            ORDER BY hourTimestamp ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_text(statement, 1, (startISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (endISO as NSString).utf8String, -1, nil)

        var hours: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let isoString = String(cString: cString)
            // Return actual timestamp (not normalized) so navigation can find frames
            guard let timestamp = formatter.date(from: isoString) else { continue }
            hours.append(timestamp)
        }

        return hours
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
