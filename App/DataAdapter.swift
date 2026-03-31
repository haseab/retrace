import Foundation
import CoreGraphics
import Shared
import Database
import Storage
import SQLCipher

/// Unified data adapter that owns connections directly and runs SQL
/// Seamlessly blends data from Retrace (native) and Rewind (encrypted) databases
public actor DataAdapter {
    private static let memoryLedgerSegmentCacheTag = "app.dataAdapter.segmentCache"

    /// High-frequency function words that should not use prefix expansion.
    /// These still participate in MATCH, but as exact token matches.
    private static let exactMatchStopwords: Set<String> = [
        "a", "an", "and", "as", "at",
        "be", "but", "by",
        "for", "from",
        "if", "in", "into", "is", "it",
        "of", "on", "or",
        "the", "to",
        "with"
    ]

    private static let searchDedupeLookbackWindow = 3
    private static let searchDedupeSameTextMaxXDelta: Double = 0.10
    private static let searchDedupeDifferentTextMaxXDelta: Double = 0.01
    private static let searchDedupeScrollShiftMinWidthRatio: Double = 0.99
    private static let searchDedupeScrollShiftMinHeightRatio: Double = 0.8
    private static let searchDedupeSameTextMinWidthRatio: Double = 0.92
    private static let searchDedupeSameTextMinHeightRatio: Double = 0.8
    private static let searchAllRawBatchSize = 150

    // MARK: - Connections

    private let retraceConnection: DatabaseConnection
    private let retraceReadConnectionPool: SQLiteReadConnectionPool
    private let retraceConfig: DatabaseConfig

    private var rewindConnection: DatabaseConnection?
    private var rewindSearchConnectionPool: SQLiteReadConnectionPool?
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
        retraceReadConnectionPool: SQLiteReadConnectionPool,
        retraceConfig: DatabaseConfig,
        retraceImageExtractor: ImageExtractor,
        database: DatabaseManager
    ) {
        self.retraceConnection = retraceConnection
        self.retraceReadConnectionPool = retraceReadConnectionPool
        self.retraceConfig = retraceConfig
        self.retraceImageExtractor = retraceImageExtractor
        self.database = database
    }

    /// Configure Rewind data source (encrypted SQLCipher database)
    public func configureRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        imageExtractor: ImageExtractor,
        cutoffDate: Date,
        searchConnectionPool: SQLiteReadConnectionPool? = nil
    ) {
        self.rewindConnection = connection
        self.rewindSearchConnectionPool = searchConnectionPool
        self.rewindConfig = config
        self.rewindImageExtractor = imageExtractor
        self.cutoffDate = cutoffDate
        updateSegmentCacheLedger()
        Log.info("[DataAdapter] Rewind source configured with cutoff \(cutoffDate)", category: .app)
    }

    @discardableResult
    public func updateRewindCutoffDate(_ cutoffDate: Date) -> Bool {
        guard rewindConnection != nil else {
            Log.info("[DataAdapter] Ignoring Rewind cutoff update because Rewind is not connected", category: .app)
            return false
        }

        self.rewindConfig = DatabaseConfig.rewind(cutoffDate: cutoffDate)
        self.cutoffDate = cutoffDate
        Log.info("[DataAdapter] Rewind cutoff updated in place to \(cutoffDate)", category: .app)
        return true
    }

    /// Disconnect Rewind data source (clears connection without deleting data)
    public func disconnectRewind() async {
        guard rewindConnection != nil else {
            Log.info("[DataAdapter] No Rewind source to disconnect", category: .app)
            return
        }
        await rewindSearchConnectionPool?.close()
        self.rewindConnection = nil
        self.rewindSearchConnectionPool = nil
        self.rewindConfig = nil
        self.rewindImageExtractor = nil
        self.cutoffDate = nil
        updateSegmentCacheLedger()
        Log.info("[DataAdapter] Rewind source disconnected", category: .app)
    }

    /// Release cached AVFoundation decode state held by frame extractors.
    public func purgeFrameExtractionCaches(reason: String) {
        (retraceImageExtractor as? FrameExtractionCacheInvalidating)?
            .purgeFrameExtractionCaches(reason: reason)
        (rewindImageExtractor as? FrameExtractionCacheInvalidating)?
            .purgeFrameExtractionCaches(reason: reason)
    }

    private static func decodeStoredPoint(_ rawValue: String?) -> (x: Double, y: Double)? {
        guard let rawValue else {
            return nil
        }
        let parts = rawValue.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return (x, y)
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
        await rewindSearchConnectionPool?.close()
        rewindSearchConnectionPool = nil
        segmentCache.removeAll()
        updateSegmentCacheLedger()
        Log.info("[DataAdapter] Shutdown complete", category: .app)
    }

    // MARK: - Connection Selection

    private var effectiveRetraceConfig: DatabaseConfig {
        guard rewindConnection != nil, let cutoffDate else {
            return retraceConfig
        }
        return retraceConfig.withMinimumDate(cutoffDate)
    }

    private var hasRewindReadSource: Bool {
        rewindConnection != nil && rewindConfig != nil
    }

    private func withNativeRead<T>(
        operation: String,
        _ body: @escaping @Sendable (DatabaseConnection, DatabaseConfig) throws -> T
    ) async throws -> T {
        let config = effectiveRetraceConfig
        return try await retraceReadConnectionPool.withConnection(operation: operation) { connection in
            try body(connection, config)
        }
    }

    private func withRewindRead<T>(
        operation: String,
        _ body: @escaping @Sendable (DatabaseConnection, DatabaseConfig) throws -> T
    ) async throws -> T {
        guard let rewindConnection, let rewindConfig else {
            throw DataAdapterError.sourceNotAvailable(.rewind)
        }
        if let rewindSearchConnectionPool {
            return try await rewindSearchConnectionPool.withConnection(operation: operation) { connection in
                try body(connection, rewindConfig)
            }
        }
        return try body(rewindConnection, rewindConfig)
    }

    private func connectionForTimestamp(_ timestamp: Date) -> (DatabaseConnection, DatabaseConfig) {
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            return (rewind, config)
        }
        return (retraceConnection, effectiveRetraceConfig)
    }

    /// Filters that require Retrace-only semantics because Rewind lacks supporting tables/data.
    private func requiresRetraceOnly(_ filters: FilterCriteria) -> Bool {
        (filters.selectedTags != nil && !filters.selectedTags!.isEmpty) ||
        filters.hiddenFilter == .onlyHidden ||
        filters.commentFilter == .commentsOnly
    }

    /// Search filters that require Retrace-only semantics.
    private func requiresRetraceOnly(_ filters: SearchFilters) -> Bool {
        (filters.selectedTagIds != nil && !filters.selectedTagIds!.isEmpty) ||
        (filters.excludedTagIds != nil && !filters.excludedTagIds!.isEmpty) ||
        filters.hiddenFilter == .onlyHidden ||
        filters.commentFilter == .commentsOnly
    }

    private static func buildDateRangeUnionClause(
        ranges: [DateRangeCriterion],
        columnName: String
    ) -> (clause: String?, bindValues: [Date]) {
        guard !ranges.isEmpty else {
            return (nil, [])
        }

        var dateClauses: [String] = []
        var bindValues: [Date] = []

        for range in ranges where range.hasBounds {
            switch (range.start, range.end) {
            case let (.some(start), .some(end)):
                if end < start {
                    dateClauses.append("(\(columnName) >= ? AND \(columnName) <= ?)")
                    bindValues.append(end)
                    bindValues.append(start)
                    continue
                }
                dateClauses.append("(\(columnName) >= ? AND \(columnName) <= ?)")
                bindValues.append(start)
                bindValues.append(end)
            case let (.some(start), .none):
                dateClauses.append("(\(columnName) >= ?)")
                bindValues.append(start)
            case let (.none, .some(end)):
                dateClauses.append("(\(columnName) <= ?)")
                bindValues.append(end)
            case (.none, .none):
                continue
            }
        }

        guard !dateClauses.isEmpty else {
            return (nil, [])
        }

        return ("(" + dateClauses.joined(separator: " OR ") + ")", bindValues)
    }

    private static func buildSourceBoundaryClause(
        config: DatabaseConfig,
        columnName: String
    ) -> (clause: String?, bindValues: [Date]) {
        var clauses: [String] = []
        var bindValues: [Date] = []

        if let minimumDate = config.minimumDate {
            clauses.append("\(columnName) >= ?")
            bindValues.append(minimumDate)
        }

        if let cutoffDate = config.cutoffDate {
            clauses.append("\(columnName) < ?")
            bindValues.append(cutoffDate)
        }

        guard !clauses.isEmpty else {
            return (nil, [])
        }

        return ("(" + clauses.joined(separator: " AND ") + ")", bindValues)
    }

    private static func buildSegmentOverlapBoundaryClause(
        config: DatabaseConfig,
        startColumnName: String,
        endColumnName: String
    ) -> (clause: String?, bindValues: [Date]) {
        var clauses: [String] = []
        var bindValues: [Date] = []

        if let minimumDate = config.minimumDate {
            clauses.append("\(endColumnName) >= ?")
            bindValues.append(minimumDate)
        }

        if let cutoffDate = config.cutoffDate {
            clauses.append("\(startColumnName) < ?")
            bindValues.append(cutoffDate)
        }

        guard !clauses.isEmpty else {
            return (nil, [])
        }

        return ("(" + clauses.joined(separator: " AND ") + ")", bindValues)
    }

    private func hasDateRangeIntersectingRewind(_ ranges: [DateRangeCriterion]) -> Bool {
        guard let cutoffDate else { return true }
        guard !ranges.isEmpty else { return true }

        return ranges.contains { range in
            let rangeStart = range.start ?? .distantPast
            return rangeStart < cutoffDate
        }
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
        if let cutoff = cutoffDate, startDate < cutoff, hasRewindReadSource {
            let effectiveEnd = min(endDate, cutoff)
            let frames = try await withRewindRead(operation: "data_adapter.frames.range.rewind") { connection, config in
                try Self.queryFramesWithVideoInfo(
                    from: startDate,
                    to: effectiveEnd,
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: nil
                )
            }
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let queryStart = retraceStart
            let frames = try await withNativeRead(operation: "data_adapter.frames.range.native") { connection, config in
                try Self.queryFramesWithVideoInfo(
                    from: queryStart,
                    to: endDate,
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: nil
                )
            }
            allFrames.append(contentsOf: frames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for date range.
    /// If the range starts before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesInRangeWithFilters(from startDate: Date, to endDate: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit
        let hiddenTagId = cachedHiddenTagId

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false
        // Rewind database doesn't have segment_tag table.
        // For tag-driven filters, only query Retrace so semantics remain correct.
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)

        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return startDate < cutoff
        }()

        func queryRetraceIfNeeded() async throws {
            guard remaining > 0, !excludeRetrace else { return }
            var retraceStart = startDate
            if let cutoff = cutoffDate {
                retraceStart = max(startDate, cutoff)
            }
            guard retraceStart < endDate else { return }
            let queryStart = retraceStart
            let requestedLimit = remaining

            let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.range.filtered.native") { connection, config in
                try Self.queryFramesInRangeWithFiltersOptimized(
                    from: queryStart,
                    to: endDate,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() async throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  let cutoff = cutoffDate,
                  hasRewindReadSource,
                  startDate < cutoff else {
                return
            }

            let effectiveEnd = min(endDate, cutoff)
            guard startDate < effectiveEnd else { return }
            let requestedLimit = remaining

            let rewindFrames = try await withRewindRead(operation: "data_adapter.frames.range.filtered.rewind") { connection, config in
                try Self.queryFramesInRangeWithFiltersOptimized(
                    from: startDate,
                    to: effectiveEnd,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try await queryRewindIfNeeded()
            try await queryRetraceIfNeeded()
        } else {
            try await queryRetraceIfNeeded()
            try await queryRewindIfNeeded()
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
        let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.most_recent.native") { connection, config in
            try Self.queryMostRecentFramesWithVideoInfo(
                limit: limit,
                connection: connection,
                config: config,
                filters: nil
            )
        }
        allFrames.append(contentsOf: retraceFrames)

        // Query Rewind
        if hasRewindReadSource {
            let rewindFrames = try await withRewindRead(operation: "data_adapter.frames.most_recent.rewind") { connection, config in
                try Self.queryMostRecentFramesWithVideoInfo(
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: nil
                )
            }
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
        let hiddenTagId = cachedHiddenTagId

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.most_recent.filtered.native") { connection, config in
                try Self.queryMostRecentFramesWithFiltersOptimized(
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            allFrames.append(contentsOf: retraceFrames)
            remaining = limit - retraceFrames.count
            Log.debug("[Filter] Got \(retraceFrames.count) frames from Retrace, need \(remaining) more", category: .database)
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        // Also skip if effective date filters cannot match data before cutoff.
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let effectiveDateRanges = filters.effectiveDateRanges
        let hasRewindDateOverlap = hasDateRangeIntersectingRewind(effectiveDateRanges)
        if remaining > 0, !excludeRewind, !hasRetraceOnlyFilters, hasRewindDateOverlap, hasRewindReadSource {
            let requestedLimit = remaining
            let rewindFrames = try await withRewindRead(operation: "data_adapter.frames.most_recent.filtered.rewind") { connection, config in
                try Self.queryMostRecentFramesWithFiltersOptimized(
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            allFrames.append(contentsOf: rewindFrames)
            Log.debug("[Filter] Got \(rewindFrames.count) frames from Rewind", category: .database)
        } else if !hasRewindDateOverlap, let cutoffDate {
            Log.debug("[Filter] Skipping Rewind query - date ranges do not overlap pre-cutoff data (cutoff=\(cutoffDate), ranges=\(effectiveDateRanges))", category: .database)
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
        if hasRewindReadSource {
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let frames = try await withRewindRead(operation: "data_adapter.frames.before.rewind") { connection, config in
                try Self.queryFramesWithVideoInfoBefore(
                    timestamp: effectiveTimestamp,
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: nil
                )
            }
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.before.native") { connection, config in
            try Self.queryFramesWithVideoInfoBefore(
                timestamp: timestamp,
                limit: limit,
                connection: connection,
                config: config,
                filters: nil
            )
        }
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames before timestamp.
    /// If timestamp is before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesBeforeWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit
        let hiddenTagId = cachedHiddenTagId

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return timestamp < cutoff
        }()

        func queryRetraceIfNeeded() async throws {
            guard remaining > 0, !excludeRetrace else { return }
            let requestedLimit = remaining
            let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.before.filtered.native") { connection, config in
                try Self.queryFramesBeforeWithFiltersOptimized(
                    timestamp: timestamp,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() async throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  hasRewindReadSource else {
                return
            }
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let requestedLimit = remaining
            let rewindFrames = try await withRewindRead(operation: "data_adapter.frames.before.filtered.rewind") { connection, config in
                try Self.queryFramesBeforeWithFiltersOptimized(
                    timestamp: effectiveTimestamp,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try await queryRewindIfNeeded()
            try await queryRetraceIfNeeded()
        } else {
            try await queryRetraceIfNeeded()
            try await queryRewindIfNeeded()
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
        if let cutoff = cutoffDate, timestamp < cutoff, hasRewindReadSource {
            let frames = try await withRewindRead(operation: "data_adapter.frames.after.rewind") { connection, config in
                try Self.queryFramesWithVideoInfoAfter(
                    timestamp: timestamp,
                    limit: limit,
                    connection: connection,
                    config: config,
                    filters: nil
                )
            }
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.after.native") { connection, config in
            try Self.queryFramesWithVideoInfoAfter(
                timestamp: timestamp,
                limit: limit,
                connection: connection,
                config: config,
                filters: nil
            )
        }
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames after timestamp.
    /// If timestamp is before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesAfterWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit
        let hiddenTagId = cachedHiddenTagId

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return timestamp < cutoff
        }()

        func queryRetraceIfNeeded() async throws {
            guard remaining > 0, !excludeRetrace else { return }
            let requestedLimit = remaining
            let retraceFrames = try await withNativeRead(operation: "data_adapter.frames.after.filtered.native") { connection, config in
                try Self.queryFramesAfterWithFiltersOptimized(
                    timestamp: timestamp,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() async throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  let cutoff = cutoffDate,
                  hasRewindReadSource,
                  timestamp < cutoff else {
                return
            }

            let requestedLimit = remaining
            let rewindFrames = try await withRewindRead(operation: "data_adapter.frames.after.filtered.rewind") { connection, config in
                try Self.queryFramesAfterWithFiltersOptimized(
                    timestamp: timestamp,
                    limit: requestedLimit,
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try await queryRewindIfNeeded()
            try await queryRetraceIfNeeded()
        } else {
            try await queryRetraceIfNeeded()
            try await queryRewindIfNeeded()
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
        if let frame = try await withNativeRead(
            operation: "data_adapter.frame.by_id.native",
            { connection, config in
                try Self.queryFrameWithVideoInfoByID(id: id, connection: connection, config: config)
            }
        ) {
            return frame
        }

        // Try Rewind if available
        if hasRewindReadSource {
            return try await withRewindRead(operation: "data_adapter.frame.by_id.rewind") { connection, config in
                try Self.queryFrameWithVideoInfoByID(id: id, connection: connection, config: config)
            }
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
            : (retraceConnection, effectiveRetraceConfig)

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
            : (retraceConnection, effectiveRetraceConfig)

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

    /// Get frame image as CGImage without JPEG encode/decode round-trips.
    /// Expects a video path returned by search results (relative or absolute).
    public func getFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?, source frameSource: FrameSource) async throws -> CGImage {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let config = frameSource == .rewind && rewindConfig != nil
            ? rewindConfig!
            : retraceConfig
        let resolvedPath: String = {
            if videoPath.hasPrefix("/") {
                return videoPath
            }
            return "\(config.storageRoot)/\(videoPath)"
        }()

        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrameCGImage(
                videoPath: resolvedPath,
                frameIndex: frameIndex,
                frameRate: frameRate
            )
        }

        return try await retraceImageExtractor.extractFrameCGImage(
            videoPath: resolvedPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )
    }

    /// Get video info for a frame
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> FrameVideoInfo? {
        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, effectiveRetraceConfig)
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
            updateSegmentCacheLedger()
        }

        var allSegments: [Segment] = []

        // Query Rewind
        if let cutoff = cutoffDate, startDate < cutoff, hasRewindReadSource {
            let effectiveEnd = min(endDate, cutoff)
            let segments = try await withRewindRead(operation: "data_adapter.segments.rewind") { connection, config in
                try Self.querySegments(
                    from: startDate,
                    to: effectiveEnd,
                    connection: connection,
                    config: config
                )
            }
            allSegments.append(contentsOf: segments)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let queryStart = retraceStart
            let segments = try await withNativeRead(operation: "data_adapter.segments.native") { connection, config in
                try Self.querySegments(
                    from: queryStart,
                    to: endDate,
                    connection: connection,
                    config: config
                )
            }
            allSegments.append(contentsOf: segments)
        }

        // Sort by start time
        allSegments.sort { $0.startDate < $1.startDate }

        // Cache
        segmentCache[cacheKey] = SegmentCacheEntry(segments: allSegments, timestamp: Date())
        updateSegmentCacheLedger()
        return allSegments
    }

    /// Invalidate the segment cache
    public func invalidateSessionCache() {
        segmentCache.removeAll()
        updateSegmentCacheLedger()
    }

    private func updateSegmentCacheLedger() {
        MemoryLedger.set(
            tag: Self.memoryLedgerSegmentCacheTag,
            bytes: Self.estimatedSegmentCacheBytes(segmentCache),
            count: segmentCache.count,
            unit: "windows",
            function: "app.dataAdapter",
            kind: "segment-cache",
            note: "estimated"
        )
    }

    private static func estimatedSegmentCacheBytes(_ cache: [SegmentCacheKey: SegmentCacheEntry]) -> Int64 {
        cache.reduce(into: Int64(0)) { total, element in
            total += Int64(MemoryLayout<SegmentCacheKey>.stride + MemoryLayout<SegmentCacheEntry>.stride)
            total += estimatedSegmentArrayBytes(element.value.segments)
        }
    }

    private static func estimatedSegmentArrayBytes(_ segments: [Segment]) -> Int64 {
        segments.reduce(into: Int64(MemoryLayout<Segment>.stride * segments.count)) { total, segment in
            total += estimatedStringBytes(segment.bundleID)
            total += estimatedOptionalStringBytes(segment.windowName)
            total += estimatedOptionalStringBytes(segment.browserUrl)
        }
    }

    private static func estimatedOptionalStringBytes(_ string: String?) -> Int64 {
        guard let string else { return 0 }
        return estimatedStringBytes(string)
    }

    private static func estimatedStringBytes(_ string: String) -> Int64 {
        Int64(MemoryLayout<String>.stride + string.utf8.count)
    }

    // MARK: - OCR Nodes

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, effectiveRetraceConfig)

        return try getAllOCRNodes(timestamp: timestamp, connection: connection, config: config)
    }

    /// Get all OCR nodes for a frame by frameID
    public func getAllOCRNodes(frameID: FrameID, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, effectiveRetraceConfig)

        return try getAllOCRNodes(frameID: frameID, connection: connection, config: config)
    }

    // MARK: - App Discovery

    /// Get distinct app bundle IDs from the configured data sources.
    /// When `source` is `nil`, returns the union across all connected sources.
    /// Caller is responsible for resolving names (use AppNameResolver.shared.resolveAll).
    public func getDistinctAppBundleIDs(source: FrameSource? = nil) async throws -> [String] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        switch source {
        case .native:
            return try await withNativeRead(operation: "data_adapter.distinct_apps.native") { connection, config in
                try Self.queryDistinctApps(connection: connection, config: config)
            }
        case .rewind:
            guard hasRewindReadSource else {
                return []
            }
            return try await withRewindRead(operation: "data_adapter.distinct_apps.rewind") { connection, config in
                try Self.queryDistinctApps(connection: connection, config: config)
            }
        case nil:
            var bundleIDs = Set<String>()

            if hasRewindReadSource {
                let rewindBundleIDs = try await withRewindRead(operation: "data_adapter.distinct_apps.rewind") { connection, config in
                    try Self.queryDistinctApps(connection: connection, config: config)
                }
                bundleIDs.formUnion(rewindBundleIDs)
            }

            let retraceBundleIDs = try await withNativeRead(operation: "data_adapter.distinct_apps.native") { connection, config in
                try Self.queryDistinctApps(connection: connection, config: config)
            }
            bundleIDs.formUnion(retraceBundleIDs)
            return Array(bundleIDs).sorted()
        case .screenMemory, .timeScroll, .pensieve, .unknown:
            return []
        }
    }

    // MARK: - URL Bounding Box Detection

    /// Get bounding box for URL in a frame's OCR text
    public func getURLBoundingBox(timestamp: Date, source frameSource: FrameSource) async throws -> URLBoundingBox? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = frameSource == .rewind && rewindConnection != nil
            ? (rewindConnection!, rewindConfig!)
            : (retraceConnection, effectiveRetraceConfig)

        return try getURLBoundingBox(timestamp: timestamp, connection: connection, config: config)
    }

    // MARK: - Full-Text Search

    /// Search across all data sources
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let startTime = Date()
        let hiddenTagId = cachedHiddenTagId
        let retraceOnlySearchFilters = requiresRetraceOnly(query.filters)
        let retraceCursor = query.cursor?.native
        let rewindCursor = query.cursor?.rewind
        let hasRewindSource = !retraceOnlySearchFilters && hasRewindReadSource
        let isOldestFirstAll = query.mode == .all && query.sortOrder == .oldestFirst

        // Cursor-aware source skipping:
        // - newest flow may skip Retrace after it has been exhausted (native cursor cleared)
        // - oldest flow may skip Rewind after it has been exhausted (rewind cursor cleared)
        let shouldSkipRetrace =
            !isOldestFirstAll &&
            query.cursor != nil &&
            retraceCursor == nil &&
            hasRewindSource
        let shouldSkipRewind =
            isOldestFirstAll &&
            query.cursor != nil &&
            rewindCursor == nil &&
            hasRewindSource

        let emptyResults = SearchResults(query: query, results: [], searchTimeMs: 0)

        let shouldSearchRetrace = !shouldSkipRetrace
        let shouldSearchRewind = hasRewindSource && !shouldSkipRewind

        enum SourceSearchBranch: Sendable {
            case retrace
            case rewind
        }

        struct SourceSearchOutcome: Sendable {
            let source: SourceSearchBranch
            let results: SearchResults
        }

        func shouldTreatSourceSearchFailureAsEmpty(_ error: Error, source: SourceSearchBranch) -> Bool {
            switch error {
            case is CancellationError:
                Log.debug("[DataAdapter] \(source) search task cancelled", category: .app)
                return true
            case DataAdapterError.sourceNotAvailable:
                Log.info("[DataAdapter] \(source) search source unavailable: \(error)", category: .app)
                return true
            default:
                return false
            }
        }

        func executeRetraceSearch() async throws -> SourceSearchOutcome {
            do {
                let results = try await withNativeRead(operation: "data_adapter.search.native") { connection, config in
                    try Self.searchConnection(
                        query: query,
                        connection: connection,
                        config: config,
                        source: .native,
                        sourceCursor: retraceCursor,
                        hiddenTagId: hiddenTagId
                    )
                }
                return SourceSearchOutcome(source: .retrace, results: results)
            } catch {
                if shouldTreatSourceSearchFailureAsEmpty(error, source: .retrace) {
                    return SourceSearchOutcome(source: .retrace, results: emptyResults)
                }

                Log.error("[DataAdapter] Retrace search failed", category: .app, error: error)
                throw error
            }
        }

        func executeRewindSearch() async throws -> SourceSearchOutcome {
            do {
                let results = try await withRewindRead(operation: "data_adapter.search.rewind") { connection, config in
                    try Self.searchConnection(
                        query: query,
                        connection: connection,
                        config: config,
                        source: .rewind,
                        sourceCursor: rewindCursor,
                        hiddenTagId: hiddenTagId
                    )
                }
                return SourceSearchOutcome(source: .rewind, results: results)
            } catch {
                if shouldTreatSourceSearchFailureAsEmpty(error, source: .rewind) {
                    return SourceSearchOutcome(source: .rewind, results: emptyResults)
                }

                Log.error("[DataAdapter] Rewind search failed", category: .app, error: error)
                throw error
            }
        }

        let searchTimeMs: () -> Int = {
            Int(Date().timeIntervalSince(startTime) * 1000)
        }

        return try await withThrowingTaskGroup(
            of: SourceSearchOutcome.self,
            returning: SearchResults.self
        ) { group in
            if shouldSearchRetrace {
                group.addTask {
                    try await executeRetraceSearch()
                }
            }
            if shouldSearchRewind {
                group.addTask {
                    try await executeRewindSearch()
                }
            }

            var retraceResults = emptyResults
            var rewindResults = emptyResults
            var retraceResolved = !shouldSearchRetrace
            var rewindResolved = !shouldSearchRewind

            func oldestFirstResult() -> SearchResults? {
                guard rewindResolved else { return nil }

                if !rewindResults.results.isEmpty {
                    group.cancelAll()

                    let pageResults = rewindResults.results
                    let nextCursor: SearchPageCursor? = {
                        if let nextRewind = rewindResults.nextCursor?.rewind {
                            return SearchPageCursor(native: retraceCursor, rewind: nextRewind)
                        }
                        // Rewind exhausted: keep cursor object so next page probes Retrace.
                        return SearchPageCursor(native: retraceCursor, rewind: nil)
                    }()

                    return SearchResults(
                        query: query,
                        results: pageResults,
                        searchTimeMs: searchTimeMs(),
                        nextCursor: nextCursor
                    )
                }

                guard retraceResolved else { return nil }

                let pageResults = retraceResults.results
                let nextCursor = retraceResults.nextCursor?.native.map {
                    SearchPageCursor(native: $0, rewind: nil)
                }

                return SearchResults(
                    query: query,
                    results: pageResults,
                    searchTimeMs: searchTimeMs(),
                    nextCursor: nextCursor
                )
            }

            func newestFirstResult() -> SearchResults? {
                guard retraceResolved else { return nil }

                if !retraceResults.results.isEmpty {
                    group.cancelAll()

                    let pageResults = retraceResults.results
                    let nextCursor: SearchPageCursor? = {
                        if let nextNative = retraceResults.nextCursor?.native {
                            return SearchPageCursor(native: nextNative, rewind: rewindCursor)
                        }
                        if hasRewindSource {
                            // Retrace exhausted: switch to Rewind probe on next page.
                            return SearchPageCursor(native: nil, rewind: rewindCursor)
                        }
                        return nil
                    }()

                    return SearchResults(
                        query: query,
                        results: pageResults,
                        searchTimeMs: searchTimeMs(),
                        nextCursor: nextCursor
                    )
                }

                guard rewindResolved else { return nil }

                let pageResults = rewindResults.results
                let nextCursor = rewindResults.nextCursor?.rewind.map {
                    SearchPageCursor(native: nil, rewind: $0)
                }

                return SearchResults(
                    query: query,
                    results: pageResults,
                    searchTimeMs: searchTimeMs(),
                    nextCursor: nextCursor
                )
            }

            while let outcome = try await group.next() {
                switch outcome.source {
                case .retrace:
                    retraceResults = outcome.results
                    retraceResolved = true
                case .rewind:
                    rewindResults = outcome.results
                    rewindResolved = true
                }

                if isOldestFirstAll, let result = oldestFirstResult() {
                    return result
                }
                if !isOldestFirstAll, let result = newestFirstResult() {
                    return result
                }
            }

            if isOldestFirstAll, let result = oldestFirstResult() {
                return result
            }
            if let result = newestFirstResult() {
                return result
            }
            return SearchResults(query: query, results: [], searchTimeMs: searchTimeMs())
        }
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

    private struct FrameWithVideoProjection {
        let encodedAtColumn: String
        let processingStatusColumn: String
        let redactionReasonColumn: String
        let captureTriggerColumn: String
        let mousePositionColumn: String
        let scrollPositionColumn: String
        let videoCurrentTimeColumn: String
    }

    private static func frameWithVideoProjection(
        source: FrameSource,
        tableAlias: String
    ) -> FrameWithVideoProjection {
        if source == .rewind {
            return FrameWithVideoProjection(
                encodedAtColumn: "NULL as encodedAt",
                processingStatusColumn: "-1 as processingStatus",
                redactionReasonColumn: "NULL as redactionReason",
                captureTriggerColumn: "NULL as captureTrigger",
                mousePositionColumn: "NULL",
                scrollPositionColumn: "NULL",
                videoCurrentTimeColumn: "NULL"
            )
        }

        return FrameWithVideoProjection(
            encodedAtColumn: "\(tableAlias).encodedAt",
            processingStatusColumn: "\(tableAlias).processingStatus",
            redactionReasonColumn: "\(tableAlias).redactionReason",
            captureTriggerColumn: "\(tableAlias).capture_trigger",
            mousePositionColumn: "\(tableAlias).mousePosition",
            scrollPositionColumn: "\(tableAlias).scrollPosition",
            videoCurrentTimeColumn: "\(tableAlias).videoCurrentTime"
        )
    }

    private static func frameWithVideoSubqueryProjection(source: FrameSource) -> FrameWithVideoProjection {
        if source == .rewind {
            return FrameWithVideoProjection(
                encodedAtColumn: "NULL as encodedAt",
                processingStatusColumn: "-1 as processingStatus",
                redactionReasonColumn: "NULL as redactionReason",
                captureTriggerColumn: "NULL as captureTrigger",
                mousePositionColumn: "NULL as mousePosition",
                scrollPositionColumn: "NULL as scrollPosition",
                videoCurrentTimeColumn: "NULL as videoCurrentTime"
            )
        }

        return FrameWithVideoProjection(
            encodedAtColumn: "encodedAt",
            processingStatusColumn: "processingStatus",
            redactionReasonColumn: "redactionReason",
            captureTriggerColumn: "capture_trigger",
            mousePositionColumn: "mousePosition",
            scrollPositionColumn: "scrollPosition",
            videoCurrentTimeColumn: "videoCurrentTime"
        )
    }

    private static func queryFramesWithVideoInfo(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveStartDate = config.applyLowerBound(to: startDate)
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard effectiveStartDate < effectiveEndDate else { return [] }

        // Build WHERE clause based on filters
        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        var bindIndex = 3 // 1 and 2 are for timestamps

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(Self.buildAppFilterClause(apps: apps, mode: filterMode))
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

        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                \(projection.encodedAtColumn),
                \(projection.processingStatusColumn),
                \(projection.redactionReasonColumn),
                \(projection.captureTriggerColumn),
                s.bundleID,
                s.windowName,
                s.browserUrl,
                \(projection.mousePositionColumn),
                \(projection.scrollPositionColumn),
                \(projection.videoCurrentTimeColumn),
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

        config.bindDate(effectiveStartDate, to: statement, at: 1)
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
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Fast unfiltered query - uses subquery to limit before join
    private static func queryMostRecentFramesWithVideoInfo(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        if let minimumDate = config.minimumDate, let cutoffDate = config.cutoffDate, minimumDate >= cutoffDate {
            return []
        }

        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")
        let subqueryProjection = Self.frameWithVideoSubqueryProjection(source: config.source)
        let boundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "createdAt")
        let boundaryWhereClause = boundaryFilter.clause.map { "WHERE \($0)" } ?? ""

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, \(subqueryProjection.encodedAtColumn), \(subqueryProjection.processingStatusColumn), \(subqueryProjection.redactionReasonColumn), \(subqueryProjection.captureTriggerColumn), \(subqueryProjection.mousePositionColumn), \(subqueryProjection.scrollPositionColumn), \(subqueryProjection.videoCurrentTimeColumn)
                FROM frame
                \(boundaryWhereClause)
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bindIndex = 1
        for date in boundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query - joins first to use bundleID index, then filters
    private static func queryMostRecentFramesWithFiltersOptimized(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        // Window/browser metadata filters support encoded include/exclude term sets.
        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        let hasWindowNameFilter = windowNameFilter.hasActiveFilters
        let hasSelectedTagFilters = filters.selectedTags != nil && !filters.selectedTags!.isEmpty
        let hasBrowserUrlFilter = browserUrlFilter.hasActiveFilters
        let hasSegmentMetadataFilter = hasBrowserUrlFilter || hasWindowNameFilter

        // Sparse metadata filters are often selective; use a segment-first query shape so SQLite doesn't
        // scan the full frame table just to satisfy ORDER BY createdAt LIMIT N.
        if hasSegmentMetadataFilter && !hasSelectedTagFilters && filters.hiddenFilter != .onlyHidden {
            return try Self.queryMostRecentFramesWithSegmentMetadataFilterSegmentFirst(
                limit: limit,
                connection: connection,
                config: config,
                filters: filters,
                hiddenTagId: hiddenTagId,
                isRewindDatabase: isRewindDatabase
            )
        }

        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase
        )
        let whereClause = filterComponents.whereClauses.isEmpty
            ? ""
            : "WHERE " + filterComponents.whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(filterComponents.combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        Log.debug("[Filter] ====== QUERY DEBUG START ======", category: .database)
        Log.debug("[Filter] Query SQL:\n\(sql)", category: .database)
        Log.debug("[Filter] Apps filter: \(filters.selectedApps ?? []), mode: \(filters.appFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Tags to filter: \(filters.selectedTags ?? []), mode: \(filters.tagFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Hidden filter: \(filters.hiddenFilter.rawValue), hiddenTagId: \(String(describing: hiddenTagId))", category: .database)
        Log.debug("[Filter] Window name filter: \(filters.windowNameFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Browser URL filter: \(filters.browserUrlFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Date ranges: \(filters.effectiveDateRanges)", category: .database)

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

        var bindIndex: Int32 = 1
        for tagId in filterComponents.includedTagIDs {
            Log.debug("[Filter] Binding tagId \(tagId) at index \(bindIndex)", category: .database)
            sqlite3_bind_int64(stmt, bindIndex, tagId)
            bindIndex += 1
        }
        for app in filterComponents.appBundleIDs {
            Log.debug("[Filter] Binding app '\(app)' at index \(bindIndex)", category: .database)
            sqlite3_bind_text(stmt, bindIndex, (app as NSString).utf8String, -1, nil)
            bindIndex += 1
        }
        for stringValue in filterComponents.metadataBindValues {
            Log.debug("[Filter] Binding metadata pattern '\(stringValue)' at index \(bindIndex)", category: .database)
            sqlite3_bind_text(stmt, bindIndex, (stringValue as NSString).utf8String, -1, nil)
            bindIndex += 1
        }
        for date in filterComponents.dateRangeBounds {
            Log.debug("[Filter] Binding date bound at index \(bindIndex)", category: .database)
            config.bindDate(date, to: stmt, at: bindIndex)
            bindIndex += 1
        }
        for date in filterComponents.sourceBoundaryBounds {
            Log.debug("[Filter] Binding source boundary at index \(bindIndex)", category: .database)
            config.bindDate(date, to: stmt, at: bindIndex)
            bindIndex += 1
        }
        for tagId in filterComponents.excludedTagIDs {
            Log.debug("[Filter] Binding exclude tagId \(tagId) at index \(bindIndex)", category: .database)
            sqlite3_bind_int64(stmt, bindIndex, tagId)
            bindIndex += 1
        }
        if let hiddenTagID = filterComponents.hiddenTagID {
            Log.debug("[Filter] Binding hiddenTagId \(hiddenTagID) at index \(bindIndex)", category: .database)
            sqlite3_bind_int64(stmt, bindIndex, hiddenTagID)
            bindIndex += 1
        }

        // Bind limit
        Log.debug("[Filter] Binding limit \(limit) at index \(bindIndex)", category: .database)
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))
        Log.debug("[Filter] ====== QUERY DEBUG END ======", category: .database)

        var frames: [FrameWithVideoInfo] = []
        var stepCount = 0
        var stepResult = sqlite3_step(stmt)

        while stepResult == SQLITE_ROW {
            stepCount += 1
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: stmt, config: config) {
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

    /// Specialized most-recent query for window name/browser URL filters.
    /// Uses a segment-first subquery to avoid scanning frame.createdAt across the full table.
    private static func queryMostRecentFramesWithSegmentMetadataFilterSegmentFirst(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool
    ) throws -> [FrameWithVideoInfo] {
        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        let hasBrowserUrlFilter = browserUrlFilter.hasActiveFilters
        let hasWindowNameFilter = windowNameFilter.hasActiveFilters
        guard hasBrowserUrlFilter || hasWindowNameFilter else {
            return []
        }

        var segmentWhereClauses: [String] = []
        var whereClauses: [String] = []
        var segmentMetadataBindValues: [String] = []

        if let apps = filters.selectedApps, !apps.isEmpty {
            segmentWhereClauses.append(Self.buildAppFilterClause(apps: apps, mode: filters.appFilterMode, tableAlias: "s2"))
        }

        Self.appendMetadataStringFilter(
            columnName: "s2.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &segmentWhereClauses,
            bindValues: &segmentMetadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s2.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &segmentWhereClauses,
            bindValues: &segmentMetadataBindValues
        )

        let segmentWhereClause = segmentWhereClauses.joined(separator: " AND ")
        whereClauses.append("""
            f.segmentId IN (
                SELECT s2.id
                FROM segment s2
                WHERE \(segmentWhereClause)
            )
            """)

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }
        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        if let sourceBoundaryClause = sourceBoundaryFilter.clause {
            whereClauses.append(sourceBoundaryClause)
        }

        // Rewind database doesn't have segment_tag; hidden filter only applies on Retrace.
        if !isRewindDatabase, filters.hiddenFilter == .hide, hiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bindIndex = 1

        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        for stringValue in segmentMetadataBindValues {
            sqlite3_bind_text(statement, Int32(bindIndex), (stringValue as NSString).utf8String, -1, nil)
            bindIndex += 1
        }

        for date in dateRangeFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        if !isRewindDatabase, filters.hiddenFilter == .hide, let hiddenTagId {
            sqlite3_bind_int64(statement, Int32(bindIndex), hiddenTagId)
            bindIndex += 1
        }

        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for frames before timestamp - joins first to use bundleID index
    private static func queryFramesBeforeWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)
        var whereClauses = ["f.createdAt < ?"]
        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase
        )
        whereClauses.append(contentsOf: filterComponents.whereClauses)
        let whereClause = whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(filterComponents.combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex: Int32 = 1
        currentBindIndex = Self.bindFrameFilterCTEValues(
            filterComponents,
            to: statement,
            startingAt: currentBindIndex
        )

        // Bind timestamp
        config.bindDate(effectiveTimestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        currentBindIndex = Self.bindFrameFilterWhereValues(
            filterComponents,
            to: statement,
            config: config,
            startingAt: currentBindIndex
        )

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for frames after timestamp - joins first to use bundleID index
    private static func queryFramesAfterWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        var whereClauses = ["f.createdAt > ?"]
        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase
        )
        whereClauses.append(contentsOf: filterComponents.whereClauses)
        let whereClause = whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(filterComponents.combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex: Int32 = 1
        currentBindIndex = Self.bindFrameFilterCTEValues(
            filterComponents,
            to: statement,
            startingAt: currentBindIndex
        )

        // Bind timestamp
        config.bindDate(timestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        currentBindIndex = Self.bindFrameFilterWhereValues(
            filterComponents,
            to: statement,
            config: config,
            startingAt: currentBindIndex
        )

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for date range - joins first to use bundleID index
    private static func queryFramesInRangeWithFiltersOptimized(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveStartDate = config.applyLowerBound(to: startDate)
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard effectiveStartDate < effectiveEndDate else { return [] }

        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase,
            includeSourceBoundary: false
        )
        whereClauses.append(contentsOf: filterComponents.whereClauses)
        let whereClause = whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(filterComponents.combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var currentBindIndex: Int32 = 1
        currentBindIndex = Self.bindFrameFilterCTEValues(
            filterComponents,
            to: statement,
            startingAt: currentBindIndex
        )

        // Bind timestamps
        config.bindDate(effectiveStartDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1
        config.bindDate(effectiveEndDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        currentBindIndex = Self.bindFrameFilterWhereValues(
            filterComponents,
            to: statement,
            config: config,
            startingAt: currentBindIndex
        )

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private static func queryFramesWithVideoInfoBefore(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)
        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "createdAt")

        // Build WHERE clause based on filters
        var whereClauses = ["createdAt < ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(Self.buildAppFilterClause(apps: apps, mode: filterMode))
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

        if let sourceBoundaryClause = sourceBoundaryFilter.clause {
            whereClauses.append(sourceBoundaryClause)
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")
        let subqueryProjection = Self.frameWithVideoSubqueryProjection(source: config.source)

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, \(subqueryProjection.encodedAtColumn), \(subqueryProjection.processingStatusColumn), \(subqueryProjection.redactionReasonColumn), \(subqueryProjection.captureTriggerColumn), \(subqueryProjection.mousePositionColumn), \(subqueryProjection.scrollPositionColumn), \(subqueryProjection.videoCurrentTimeColumn)
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

        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private static func queryFramesWithVideoInfoAfter(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "createdAt")

        // Build WHERE clause based on filters
        var whereClauses = ["createdAt > ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(Self.buildAppFilterClause(apps: apps, mode: filterMode))
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

        if let sourceBoundaryClause = sourceBoundaryFilter.clause {
            whereClauses.append(sourceBoundaryClause)
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")
        let subqueryProjection = Self.frameWithVideoSubqueryProjection(source: config.source)

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, \(subqueryProjection.encodedAtColumn), \(subqueryProjection.processingStatusColumn), \(subqueryProjection.redactionReasonColumn), \(subqueryProjection.captureTriggerColumn), \(subqueryProjection.mousePositionColumn), \(subqueryProjection.scrollPositionColumn), \(subqueryProjection.videoCurrentTimeColumn)
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

        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private static func queryFrameWithVideoInfoByID(
        id: FrameID,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameWithVideoInfo? {
        // Normalize native-only frame columns across Retrace and Rewind.
        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        let boundaryClause = sourceBoundaryFilter.clause.map { " AND \($0)" } ?? ""

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, \(projection.encodedAtColumn), \(projection.processingStatusColumn), \(projection.redactionReasonColumn),
                   \(projection.captureTriggerColumn),
                   s.bundleID, s.windowName, s.browserUrl, \(projection.mousePositionColumn), \(projection.scrollPositionColumn), \(projection.videoCurrentTimeColumn),
                   v.path, v.frameRate, v.width, v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.id = ?\(boundaryClause)
            """

        guard let statement = try? connection.prepare(sql: sql) else { return nil }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, id.value)
        var bindIndex = 2
        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        return try Self.parseFrameWithVideoInfo(statement: statement, config: config)
    }

    private func getFrameVideoInfo(
        segmentID: VideoSegmentID,
        timestamp: Date,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameVideoInfo? {
        guard config.contains(timestamp) else { return nil }

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

        guard let relativePath = Self.getTextOrNil(statement, 1) else { return nil }

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

    private static func querySegments(
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
            if let segment = try? Self.parseSegment(statement: statement, config: config) {
                segments.append(segment)
            }
        }

        return segments
    }

    private func getAllOCRNodes(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> [OCRNodeWithText] {
        guard config.contains(timestamp) else { return [] }

        // First find the frame ID
        let frameSql = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1;"
        guard let frameStatement = try? connection.prepare(sql: frameSql) else { return [] }
        defer { connection.finalize(frameStatement) }

        config.bindDate(timestamp, to: frameStatement, at: 1)

        guard sqlite3_step(frameStatement) == SQLITE_ROW else { return [] }

        let frameID = FrameID(value: sqlite3_column_int64(frameStatement, 0))
        return try getAllOCRNodes(frameID: frameID, connection: connection, config: config)
    }

    private func getAllOCRNodes(frameID: FrameID, connection: DatabaseConnection, config: DatabaseConfig) throws -> [OCRNodeWithText] {
        let redactedColumn = config.source == .rewind
            ? "0 as redacted"
            : "CASE WHEN n.encryptedText IS NOT NULL THEN 1 ELSE 0 END as redacted"
        let nodeTextColumn: String
        let encryptedTextColumn: String
        if config.source == .rewind {
            nodeTextColumn = "SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength) as nodeText"
            encryptedTextColumn = "NULL as encryptedText"
        } else {
            nodeTextColumn = """
                CASE
                    WHEN n.encryptedText IS NOT NULL THEN printf('%.*c', n.textLength, ' ')
                    ELSE SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)
                END as nodeText
                """
            encryptedTextColumn = "n.encryptedText as encryptedText"
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
                \(redactedColumn),
                \(nodeTextColumn),
                \(encryptedTextColumn),
                n.frameId
            FROM node n
            LEFT JOIN doc_segment ds ON n.frameId = ds.frameId
            LEFT JOIN searchRanking_content sc ON ds.docid = sc.id
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

    private static func queryDistinctApps(connection: DatabaseConnection, config: DatabaseConfig) throws -> [String] {
        let sourceBoundaryFilter = Self.buildSegmentOverlapBoundaryClause(
            config: config,
            startColumnName: "s.startDate",
            endColumnName: "s.endDate"
        )
        let boundaryClause = sourceBoundaryFilter.clause.map { " AND \($0)" } ?? ""
        let sql = """
            SELECT DISTINCT s.bundleID
            FROM segment s
            WHERE s.bundleID IS NOT NULL AND s.bundleID != ''\(boundaryClause)
            LIMIT 100;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bindIndex = 1
        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        var bundleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIDPtr = sqlite3_column_text(statement, 0) else { continue }
            bundleIDs.append(String(cString: bundleIDPtr))
        }

        return bundleIDs
    }

    private func getURLBoundingBox(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> URLBoundingBox? {
        guard config.contains(timestamp) else { return nil }

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
        let matchTerms = urlBoundingBoxMatchTerms(for: browserUrl)
        guard !matchTerms.isEmpty else { return nil }

        // Get FTS content
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM searchRanking_content src
            JOIN (
                SELECT MAX(docid) AS docid
                FROM doc_segment
                WHERE frameId = ?
            ) ds ON ds.docid = src.id;
            """

        guard let ftsStmt = try? connection.prepare(sql: ftsSQL) else { return nil }
        defer { connection.finalize(ftsStmt) }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else { return nil }

        let c0Text = sqlite3_column_text(ftsStmt, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text
        let c0Length = c0Text.count

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

        var bestMatch: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?
        var bestPathFallback: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let textOffset = Int(sqlite3_column_int(nodesStmt, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt, 6))
            let isOtherTextNode = textOffset >= c0Length

            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])
            let normalizedNodeText = nodeText.lowercased()
            let hasPathLikeText = nodeText.contains("/") || nodeText.contains("?") || nodeText.contains("&") || nodeText.contains("=")
            if hasPathLikeText {
                // Fallback path for OCR cases where host text is missing but the address bar path is present.
                // Keep this conservative: top-of-frame, non-trivial width, and URL-like text.
                var fallbackScore = 0
                if topY <= 0.06 { fallbackScore += 95 }
                else if topY <= 0.11 { fallbackScore += 80 }
                else if topY <= 0.15 { fallbackScore += 55 }
                else if topY <= 0.20 { fallbackScore += 20 }

                let topBiasBonus = max(0, Int((0.22 - Double(topY)) * 200.0))
                fallbackScore += topBiasBonus
                if !nodeText.contains(" ") { fallbackScore += 60 }
                if width >= 0.05 { fallbackScore += 20 }
                if width >= 0.12 { fallbackScore += 20 }
                if isOtherTextNode { fallbackScore += 65 }

                if let current = bestPathFallback {
                    if fallbackScore > current.score || (fallbackScore == current.score && topY < current.y) {
                        bestPathFallback = (x: leftX, y: topY, width: width, height: height, score: fallbackScore)
                    }
                } else {
                    bestPathFallback = (x: leftX, y: topY, width: width, height: height, score: fallbackScore)
                }
            }

            let matchingTerm = matchTerms
                .filter { normalizedNodeText.contains($0) }
                .max(by: { $0.count < $1.count })
            guard let matchingTerm else { continue }

            var score = 0
            let matchRatio = Double(matchingTerm.count) / Double(max(nodeText.count, 1))
            if matchRatio > 0.6 { score += 40 }
            else if matchRatio > 0.3 { score += 28 }
            else { score += 14 }

            // Prefer higher text candidates; URL bars are consistently near the top.
            if topY <= 0.06 { score += 95 }
            else if topY <= 0.11 { score += 80 }
            else if topY <= 0.15 { score += 55 }
            else if topY <= 0.20 { score += 25 }

            let topBiasBonus = max(0, Int((0.22 - Double(topY)) * 260.0))
            score += topBiasBonus

            // Strongly prefer path/query-like URL text over bare hostnames.
            if hasPathLikeText && !nodeText.contains(" ") {
                score += 95
            } else if hasPathLikeText {
                score += 45
            }
            if isOtherTextNode {
                // `c1` / `otherText` is short chrome-like text; prioritize it for URL bar targeting.
                score += 85
            }

            if let current = bestMatch {
                if score > current.score || (score == current.score && topY < current.y) {
                    bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
                }
            } else {
                bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
            }
        }

        guard let bounds = bestMatch ?? bestPathFallback else { return nil }

        return URLBoundingBox(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            url: browserUrl
        )
    }

    private func urlBoundingBoxMatchTerms(for browserURL: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()

        func appendHostVariants(_ rawHost: String?) {
            guard let rawHost else { return }
            let host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return }
            if seen.insert(host).inserted { terms.append(host) }

            if host.hasPrefix("www.") {
                let withoutWWW = String(host.dropFirst(4))
                if !withoutWWW.isEmpty, seen.insert(withoutWWW).inserted {
                    terms.append(withoutWWW)
                }
            }
        }

        if let url = URL(string: browserURL) {
            appendHostVariants(url.host)

            // Handle redirect wrappers like google.com/url?q=https://target...
            let redirectQueryKeys: Set<String> = ["q", "url", "u", "target", "dest", "destination", "to"]
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                for item in components.queryItems ?? [] {
                    guard redirectQueryKeys.contains(item.name.lowercased()),
                          let value = item.value,
                          !value.isEmpty else {
                        continue
                    }
                    let decoded = value.removingPercentEncoding ?? value
                    appendHostVariants(URL(string: decoded)?.host)
                }
            }
        } else {
            appendHostVariants(browserURL)
        }

        return terms
    }

    private static func searchConnection(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource,
        sourceCursor: SearchSourceCursor?,
        hiddenTagId: Int64?
    ) throws -> SearchResults {
        switch query.mode {
        case .relevant:
            return try searchRelevant(
                query: query,
                connection: connection,
                config: config,
                source: source,
                sourceCursor: sourceCursor,
                hiddenTagId: hiddenTagId
            )
        case .all:
            return try searchAll(
                query: query,
                connection: connection,
                config: config,
                source: source,
                sourceCursor: sourceCursor,
                hiddenTagId: hiddenTagId
            )
        }
    }

    private static func searchRelevant(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource,
        sourceCursor: SearchSourceCursor?,
        hiddenTagId: Int64?
    ) throws -> SearchResults {
        let startTime = Date()
        let ftsQueryComponents = parseFTSQueryComponents(query.text)
        let ftsQuery = scopeToSearchableTextColumns(ftsQueryComponents)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let redactionReasonColumn = source == .rewind ? "NULL as redaction_reason" : "f.redactionReason as redaction_reason"
        let captureTriggerColumn = source == .rewind ? "NULL as capture_trigger" : "f.capture_trigger as capture_trigger"
        let normalizedOffset = max(0, query.offset)
        let rankCursor = decodeRelevantCursor(sourceCursor)
        let rawBatchLimit = max(query.limit, Self.searchAllRawBatchSize)
        let batchOffset: Int? = rankCursor == nil ? normalizedOffset : nil

        // Build WHERE conditions for the batch query (filters applied after FTS subquery).
        var outerWhereConditions: [String] = []
        var outerBindValues: [Any] = []

        let outerDateRangeFilter = buildDateRangeUnionClause(
            ranges: query.filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = outerDateRangeFilter.clause {
            outerWhereConditions.append(dateRangeClause)
            outerBindValues.append(contentsOf: outerDateRangeFilter.bindValues.map(config.formatDate))
        }
        let sourceBoundaryFilter = buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        if let sourceBoundaryClause = sourceBoundaryFilter.clause {
            outerWhereConditions.append(sourceBoundaryClause)
            outerBindValues.append(contentsOf: sourceBoundaryFilter.bindValues.map(config.formatDate))
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

        // Advanced metadata filters (single-value legacy and encoded multi-value include/exclude).
        let windowNameFilter = decodeMetadataStringFilter(query.filters.windowNameFilter)
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &outerWhereConditions,
            bindValues: &outerBindValues
        )

        let browserUrlFilter = decodeMetadataStringFilter(query.filters.browserUrlFilter)
        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &outerWhereConditions,
            bindValues: &outerBindValues
        )

        // Tag include filter - use INNER JOIN (more efficient than EXISTS subquery)
        // Note: Skip tag filters for Rewind database (it doesn't have segment_tag table)
        // When no tags selected, tagJoin is empty and no join happens
        let isRewind = source == .rewind
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
                if let hiddenTagId {
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
                if let hiddenTagId {
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

        if let commentClause = Self.buildCommentFilterClause(
            query.filters.commentFilter,
            isRewindDatabase: isRewind,
            segmentIDExpression: "f.segmentId"
        ) {
            outerWhereConditions.append(commentClause)
        }

        var cursorConditions: [String] = []
        if rankCursor != nil {
            cursorConditions.append("(r.rank > ? OR (r.rank = ? AND f.id > ?))")
        }

        let highlightTerms = parseSearchDedupeTokens(query.text).map(\.matchingTerm).filter { !$0.isEmpty }
        let visibleNodeTextSQL = isRewind
            ? "SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)"
            : """
                CASE
                    WHEN n.encryptedText IS NOT NULL THEN printf('%.*c', n.textLength, ' ')
                    ELSE SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)
                END
                """
        let highlightMatchClause: String = {
            guard !highlightTerms.isEmpty else { return "0" }
            return highlightTerms.map { _ in
                "INSTR(LOWER(\(visibleNodeTextSQL)), ?) > 0"
            }.joined(separator: " OR ")
        }()

        struct RelevantSearchRow {
            let frameId: Int64
            let timestamp: Date
            let segmentId: Int64
            let videoId: Int64
            let frameIndex: Int
            let videoPath: String?
            let videoFrameRate: Double?
            let redactionReason: String?
            let captureTrigger: FrameCaptureTrigger?
            let appBundleID: String?
            let windowName: String?
            let browserUrl: String?
            let rank: Double
            let docID: Int64
            let highlightNode: SearchResult.HighlightNode?
            let highlightTextSignature: String?
        }

        let allWhereConditions = outerWhereConditions + cursorConditions
        let batchWhereClause = allWhereConditions.isEmpty ? "" : "WHERE " + allWhereConditions.joined(separator: " AND ")
        let rankedBaseLimit = (outerWhereConditions.isEmpty && tagJoinBindValues.isEmpty && cursorConditions.isEmpty) ? rawBatchLimit : rawBatchLimit * 10
        let rankedLimit = rankedBaseLimit + (batchOffset ?? 0)
        let includeOffset = batchOffset != nil

        let sql = """
            WITH ranked AS MATERIALIZED (
                SELECT
                    rowid AS docid,
                    bm25(searchRanking) AS rank
                FROM searchRanking
                WHERE searchRanking MATCH ?
                ORDER BY bm25(searchRanking) ASC, rowid ASC
                LIMIT ? \(includeOffset ? "OFFSET ?" : "")
            ),
            batch AS MATERIALIZED (
                SELECT
                    f.id AS frame_id,
                    f.createdAt AS timestamp,
                    f.segmentId AS segment_id,
                    f.videoId AS video_id,
                    f.videoFrameIndex AS frame_index,
                    v.path AS video_path,
                    v.frameRate AS video_frame_rate,
                    \(redactionReasonColumn),
                    \(captureTriggerColumn),
                    s.bundleID AS bundle_id,
                    s.windowName AS window_name,
                    s.browserUrl AS browser_url,
                    r.rank AS rank,
                    r.docid AS docid
                FROM ranked r
                JOIN doc_segment ds ON r.docid = ds.docid
                JOIN frame f ON ds.frameId = f.id
                JOIN segment s ON f.segmentId = s.id
                LEFT JOIN video v ON v.id = f.videoId
                \(tagJoin)
                \(batchWhereClause)
                ORDER BY r.rank ASC, f.id ASC
                LIMIT ?
            ),
            node_candidates AS MATERIALIZED (
                SELECT
                    b.frame_id,
                    b.docid,
                    n.id AS node_id,
                    n.nodeOrder AS node_order,
                    n.leftX AS left_x,
                    n.topY AS top_y,
                    n.width AS node_width,
                    n.height AS node_height,
                    LOWER(
                        TRIM(
                            REPLACE(
                                REPLACE(
                                    \(visibleNodeTextSQL),
                                    char(10),
                                    ' '
                                ),
                                char(13),
                                ' '
                            )
                        )
                    ) AS node_text_signature,
                    ROW_NUMBER() OVER (
                        PARTITION BY b.frame_id, b.docid
                        ORDER BY n.nodeOrder ASC
                    ) AS rn
                FROM batch b
                JOIN node n ON n.frameId = b.frame_id
                JOIN searchRanking_content sc ON sc.id = b.docid
                WHERE \(highlightMatchClause)
            ),
            first_node AS MATERIALIZED (
                SELECT
                    frame_id,
                    docid,
                    node_id,
                    node_order,
                    left_x,
                    top_y,
                    node_width,
                    node_height,
                    node_text_signature
                FROM node_candidates
                WHERE rn = 1
            )
            SELECT
                b.frame_id,
                b.timestamp,
                b.segment_id,
                b.video_id,
                b.frame_index,
                b.video_path,
                b.video_frame_rate,
                b.redaction_reason,
                b.capture_trigger,
                b.bundle_id,
                b.window_name,
                b.browser_url,
                b.rank,
                b.docid,
                fn.node_id,
                fn.node_order,
                fn.left_x,
                fn.top_y,
                fn.node_width,
                fn.node_height,
                fn.node_text_signature
            FROM batch b
            LEFT JOIN first_node fn ON fn.frame_id = b.frame_id AND fn.docid = b.docid
            ORDER BY b.rank ASC, b.frame_id ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return SearchResults(query: query, results: [], searchTimeMs: 0)
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, Int64(rankedLimit))
        bindIndex += 1

        if let batchOffset {
            sqlite3_bind_int64(statement, bindIndex, Int64(batchOffset))
            bindIndex += 1
        }

        for tagId in tagJoinBindValues {
            sqlite3_bind_int64(statement, bindIndex, tagId)
            bindIndex += 1
        }

        for value in outerBindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(statement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        if let rankCursor {
            sqlite3_bind_double(statement, bindIndex, rankCursor.rank)
            bindIndex += 1
            sqlite3_bind_double(statement, bindIndex, rankCursor.rank)
            bindIndex += 1
            sqlite3_bind_int64(statement, bindIndex, rankCursor.frameId)
            bindIndex += 1
        }

        sqlite3_bind_int64(statement, bindIndex, Int64(rawBatchLimit))
        bindIndex += 1

        for term in highlightTerms {
            sqlite3_bind_text(statement, bindIndex, term, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        var batch: [RelevantSearchRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameId = sqlite3_column_int64(statement, 0)
            let timestamp = config.parseDate(from: statement, column: 1) ?? Date()
            let segmentId = sqlite3_column_int64(statement, 2)
            let videoId = sqlite3_column_int64(statement, 3)
            let frameIndex = Int(sqlite3_column_int(statement, 4))
            let videoPath = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let videoFrameRate: Double? = {
                guard sqlite3_column_type(statement, 6) != SQLITE_NULL else { return nil }
                return sqlite3_column_double(statement, 6)
            }()
            let redactionReason = sqlite3_column_text(statement, 7).map { String(cString: $0) }
            let captureTrigger = sqlite3_column_text(statement, 8)
                .map { String(cString: $0) }
                .flatMap(FrameCaptureTrigger.init(rawValue:))
            let appBundleID = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 10).map { String(cString: $0) }
            let browserUrl = sqlite3_column_text(statement, 11).map { String(cString: $0) }
            let rank = sqlite3_column_double(statement, 12)
            let docID = sqlite3_column_int64(statement, 13)

            let highlightNode: SearchResult.HighlightNode?
            if sqlite3_column_type(statement, 14) != SQLITE_NULL {
                highlightNode = SearchResult.HighlightNode(
                    nodeID: sqlite3_column_int64(statement, 14),
                    nodeOrder: Int(sqlite3_column_int(statement, 15)),
                    x: sqlite3_column_double(statement, 16),
                    y: sqlite3_column_double(statement, 17),
                    width: sqlite3_column_double(statement, 18),
                    height: sqlite3_column_double(statement, 19)
                )
            } else {
                highlightNode = nil
            }
            let highlightTextSignature = sqlite3_column_text(statement, 20).map { String(cString: $0) }

            batch.append(
                RelevantSearchRow(
                    frameId: frameId,
                    timestamp: timestamp,
                    segmentId: segmentId,
                    videoId: videoId,
                    frameIndex: frameIndex,
                    videoPath: videoPath,
                    videoFrameRate: videoFrameRate,
                    redactionReason: redactionReason,
                    captureTrigger: captureTrigger,
                    appBundleID: appBundleID,
                    windowName: windowName,
                    browserUrl: browserUrl,
                    rank: rank,
                    docID: docID,
                    highlightNode: highlightNode,
                    highlightTextSignature: highlightTextSignature
                )
            )
        }

        let sourceRowsFetched = batch.count
        var dedupedRows: [RelevantSearchRow] = []
        var recentAnchors: [SearchDedupeMatchBox] = []
        var recentWindowNameSignatures: [String] = []

        for row in batch {
            let currentWindowNameSignature = normalizedWindowNameSignature(row.windowName)
            if let highlightNode = row.highlightNode {
                let currentAnchor = SearchDedupeMatchBox(
                    label: "highlight",
                    textSignature: normalizedSearchDedupeTextSignature(row.highlightTextSignature) ?? "",
                    nodeOrder: highlightNode.nodeOrder,
                    xBin: quantizedNodeBin(highlightNode.x),
                    yBin: quantizedNodeBin(highlightNode.y),
                    wBin: max(1, quantizedNodeBin(highlightNode.width)),
                    hBin: max(1, quantizedNodeBin(highlightNode.height))
                )
                if recentAnchors.contains(where: { areConsecutiveDedupeBoxesSimilar($0, currentAnchor) }) {
                    continue
                }
                recentAnchors.append(currentAnchor)
                if recentAnchors.count > Self.searchDedupeLookbackWindow {
                    recentAnchors.removeFirst(recentAnchors.count - Self.searchDedupeLookbackWindow)
                }
            } else {
                recentAnchors.removeAll(keepingCapacity: true)
            }

            if let currentWindowNameSignature,
               recentWindowNameSignatures.contains(where: { areConsecutiveWindowNamesSimilar($0, currentWindowNameSignature) }) {
                continue
            }

            dedupedRows.append(row)
            if let currentWindowNameSignature {
                recentWindowNameSignatures.append(currentWindowNameSignature)
                if recentWindowNameSignatures.count > Self.searchDedupeLookbackWindow {
                    recentWindowNameSignatures.removeFirst(recentWindowNameSignatures.count - Self.searchDedupeLookbackWindow)
                }
            } else {
                recentWindowNameSignatures.removeAll(keepingCapacity: true)
            }
        }

        let nextSourceCursor: SearchSourceCursor?
        if sourceRowsFetched == rawBatchLimit, let lastFetched = batch.last {
            nextSourceCursor = SearchSourceCursor(
                timestamp: encodeRelevantCursorRank(lastFetched.rank),
                frameID: lastFetched.frameId
            )
        } else {
            nextSourceCursor = nil
        }
        let nextCursor: SearchPageCursor? = {
            guard let nextSourceCursor else { return nil }
            if source == .rewind {
                return SearchPageCursor(rewind: nextSourceCursor)
            }
            return SearchPageCursor(native: nextSourceCursor)
        }()

        guard !dedupedRows.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], searchTimeMs: elapsed, nextCursor: nextCursor)
        }

        let results = dedupedRows.map { row in
            let appName = row.appBundleID?.components(separatedBy: ".").last
            return SearchResult(
                id: FrameID(value: row.frameId),
                timestamp: row.timestamp,
                snippet: "",
                matchedText: query.text,
                relevanceScore: abs(row.rank) / (1.0 + abs(row.rank)),
                metadata: FrameMetadata(
                    appBundleID: row.appBundleID,
                    appName: appName,
                    windowName: row.windowName,
                    browserURL: row.browserUrl,
                    redactionReason: row.redactionReason,
                    captureTrigger: row.captureTrigger,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: row.segmentId),
                videoID: VideoSegmentID(value: row.videoId),
                frameIndex: row.frameIndex,
                videoPath: row.videoPath,
                videoFrameRate: row.videoFrameRate,
                source: source,
                highlightNode: row.highlightNode
            )
        }

        let totalElapsed = Int(Date().timeIntervalSince(startTime) * 1000)

        return SearchResults(
            query: query,
            results: results,
            searchTimeMs: totalElapsed,
            nextCursor: nextCursor
        )
    }

    private static func searchAll(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource,
        sourceCursor: SearchSourceCursor?,
        hiddenTagId: Int64?
    ) throws -> SearchResults {
        let startTime = Date()
        let ftsQueryComponents = parseFTSQueryComponents(query.text)
        let ftsQuery = scopeToSearchableTextColumns(ftsQueryComponents)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let redactionReasonColumn = source == .rewind ? "NULL as redaction_reason" : "f.redactionReason as redaction_reason"
        let captureTriggerColumn = source == .rewind ? "NULL as capture_trigger" : "f.capture_trigger as capture_trigger"
        let normalizedOffset = max(0, query.offset)

        // Build WHERE conditions for outer query
        var whereConditions: [String] = []
        var bindValues: [Any] = []

        let whereDateRangeFilter = buildDateRangeUnionClause(
            ranges: query.filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = whereDateRangeFilter.clause {
            whereConditions.append(dateRangeClause)
            bindValues.append(contentsOf: whereDateRangeFilter.bindValues.map(config.formatDate))
        }
        let sourceBoundaryFilter = buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        if let sourceBoundaryClause = sourceBoundaryFilter.clause {
            whereConditions.append(sourceBoundaryClause)
            bindValues.append(contentsOf: sourceBoundaryFilter.bindValues.map(config.formatDate))
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

        // Advanced metadata filters (single-value legacy and encoded multi-value include/exclude).
        let windowNameFilter = decodeMetadataStringFilter(query.filters.windowNameFilter)
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereConditions,
            bindValues: &bindValues
        )

        let browserUrlFilter = decodeMetadataStringFilter(query.filters.browserUrlFilter)
        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereConditions,
            bindValues: &bindValues
        )

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
                if let hiddenTagId {
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
                if let hiddenTagId {
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

        if let commentClause = Self.buildCommentFilterClause(
            query.filters.commentFilter,
            isRewindDatabase: isRewind,
            segmentIDExpression: "f.segmentId"
        ) {
            whereConditions.append(commentClause)
        }

        // Determine if we need the segment table join (for app filter or tag/hidden filters)
        let hasTagFilters = hasTagIncludeFilter ||
            (!isRewind && query.filters.excludedTagIds != nil && !query.filters.excludedTagIds!.isEmpty) ||
            (!isRewind && query.filters.hiddenFilter != .showAll)
        let hasMetadataFilters = windowNameFilter.hasActiveFilters || browserUrlFilter.hasActiveFilters

        let useRewindDocIDFastPath =
            source == .rewind &&
            !hasAppFilter &&
            !hasTagFilters &&
            !hasMetadataFilters &&
            whereConditions.isEmpty &&
            tagJoinBindValues.isEmpty &&
            bindValues.isEmpty
        let rewindDocIDOrderClause = query.sortOrder == .newestFirst ? "DESC" : "ASC"

        // CTE MATERIALIZED approach: Force SQLite to compute FTS results first
        // Without MATERIALIZED, SQLite may inline the CTE and optimize it poorly
        // Tag include uses INNER JOIN (more efficient than EXISTS in WHERE clause)
        // Determine sort order
        let sortOrderClause = query.sortOrder == .newestFirst ? "DESC" : "ASC"
        // Keep FTS candidate preselection aligned with requested chronology.
        // The no-filter fast path limits candidate docids before joining frames.
        // If this stays DESC unconditionally, oldest-first can never surface old matches.
        let ftsCandidateOrderClause = query.sortOrder == .newestFirst ? "DESC" : "ASC"
        let highlightTerms = parseSearchDedupeTokens(query.text).map(\.matchingTerm).filter { !$0.isEmpty }

        struct FrameSearchRow {
            let frameId: Int64
            let timestamp: Date
            let segmentId: Int64
            let videoId: Int64
            let frameIndex: Int
            let videoPath: String?
            let videoFrameRate: Double?
            let redactionReason: String?
            let captureTrigger: FrameCaptureTrigger?
            let appBundleID: String?
            let windowName: String?
            let browserUrl: String?
            let docID: Int64
            let highlightNode: SearchResult.HighlightNode?
            let highlightTextSignature: String?
        }

        struct FrameCursor {
            let timestamp: Date
            let frameId: Int64
        }

        let visibleNodeTextSQL = isRewind
            ? "SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)"
            : """
                CASE
                    WHEN n.encryptedText IS NOT NULL THEN printf('%.*c', n.textLength, ' ')
                    ELSE SUBSTR(COALESCE(sc.c0, '') || COALESCE(sc.c1, ''), n.textOffset + 1, n.textLength)
                END
                """
        let highlightMatchClause: String = {
            guard !highlightTerms.isEmpty else { return "0" }
            return highlightTerms.map { _ in
                "INSTR(LOWER(\(visibleNodeTextSQL)), ?) > 0"
            }.joined(separator: " OR ")
        }()

        func fetchFrameBatch(limit: Int, offset: Int?, cursor: FrameCursor?) throws -> [FrameSearchRow] {
            let isOffsetQuery = offset != nil
            let canUseRewindDocIDFastPath = useRewindDocIDFastPath && cursor == nil

            var cursorConditions: [String] = []
            var cursorBindValues: [Any] = []
            if let cursor {
                if query.sortOrder == .newestFirst {
                    cursorConditions.append("(f.createdAt < ? OR (f.createdAt = ? AND f.id < ?))")
                } else {
                    cursorConditions.append("(f.createdAt > ? OR (f.createdAt = ? AND f.id > ?))")
                }
                let cursorDate = config.formatDate(cursor.timestamp)
                cursorBindValues.append(cursorDate)
                cursorBindValues.append(cursorDate)
                cursorBindValues.append(cursor.frameId)
            }

            let batchSQL: String
            var bindValuesForBatch: [Any] = [ftsQuery]

            if canUseRewindDocIDFastPath {
                batchSQL = """
                    WITH fts_docs AS MATERIALIZED (
                        SELECT rowid AS docid
                        FROM searchRanking
                        WHERE searchRanking MATCH ?
                        ORDER BY rowid \(rewindDocIDOrderClause)
                        LIMIT ? \(isOffsetQuery ? "OFFSET ?" : "")
                    )
                    SELECT
                        f.id AS frame_id,
                        f.createdAt AS timestamp,
                        f.segmentId AS segment_id,
                        f.videoId AS video_id,
                        f.videoFrameIndex AS frame_index,
                        v.path AS video_path,
                        v.frameRate AS video_frame_rate,
                        \(redactionReasonColumn),
                        \(captureTriggerColumn),
                        s.bundleID AS bundle_id,
                        s.windowName AS window_name,
                        s.browserUrl AS browser_url,
                        d.docid AS docid
                    FROM fts_docs d
                    JOIN doc_segment ds ON ds.docid = d.docid
                    JOIN frame f ON f.id = ds.frameId
                    JOIN segment s ON s.id = f.segmentId
                    LEFT JOIN video v ON v.id = f.videoId
                    ORDER BY d.docid \(rewindDocIDOrderClause)
                    """
                bindValuesForBatch.append(Int64(limit))
                if let offset {
                    bindValuesForBatch.append(Int64(offset))
                }
            } else if hasAppFilter || hasTagFilters || hasMetadataFilters {
                let allWhereConditions = whereConditions + cursorConditions
                let batchWhereClause = allWhereConditions.isEmpty ? "" : "WHERE " + allWhereConditions.joined(separator: " AND ")
                batchSQL = """
                    WITH fts_matches AS MATERIALIZED (
                        SELECT rowid AS docid FROM searchRanking WHERE searchRanking MATCH ?
                    )
                    SELECT
                        f.id AS frame_id,
                        f.createdAt AS timestamp,
                        f.segmentId AS segment_id,
                        f.videoId AS video_id,
                        f.videoFrameIndex AS frame_index,
                        v.path AS video_path,
                        v.frameRate AS video_frame_rate,
                        \(redactionReasonColumn),
                        \(captureTriggerColumn),
                        s.bundleID AS bundle_id,
                        s.windowName AS window_name,
                        s.browserUrl AS browser_url,
                        ds.docid AS docid
                    FROM fts_matches fts
                    JOIN doc_segment ds ON fts.docid = ds.docid
                    JOIN frame f ON ds.frameId = f.id
                    JOIN segment s ON f.segmentId = s.id
                    LEFT JOIN video v ON v.id = f.videoId
                    \(tagJoin)
                    \(batchWhereClause)
                    ORDER BY f.createdAt \(sortOrderClause), f.id \(sortOrderClause)
                    LIMIT ? \(isOffsetQuery ? "OFFSET ?" : "")
                    """
                bindValuesForBatch.append(contentsOf: tagJoinBindValues)
                bindValuesForBatch.append(contentsOf: bindValues)
                bindValuesForBatch.append(contentsOf: cursorBindValues)
                bindValuesForBatch.append(Int64(limit))
                if let offset {
                    bindValuesForBatch.append(Int64(offset))
                }
            } else {
                let docIDScopeCondition: String
                if isOffsetQuery {
                    let ftsLimit = limit + (offset ?? 0)
                    docIDScopeCondition = "ds.docid IN (SELECT rowid FROM searchRanking WHERE searchRanking MATCH ? ORDER BY rowid \(ftsCandidateOrderClause) LIMIT \(ftsLimit))"
                } else {
                    // Cursor/keyset queries should not be bounded by an offset-oriented FTS cap.
                    docIDScopeCondition = "ds.docid IN (SELECT rowid FROM searchRanking WHERE searchRanking MATCH ?)"
                }
                var allWhereConditions = [docIDScopeCondition]
                allWhereConditions.append(contentsOf: whereConditions)
                allWhereConditions.append(contentsOf: cursorConditions)
                let batchWhereClause = "WHERE " + allWhereConditions.joined(separator: " AND ")
                batchSQL = """
                    SELECT
                        f.id AS frame_id,
                        f.createdAt AS timestamp,
                        f.segmentId AS segment_id,
                        f.videoId AS video_id,
                        f.videoFrameIndex AS frame_index,
                        v.path AS video_path,
                        v.frameRate AS video_frame_rate,
                        \(redactionReasonColumn),
                        \(captureTriggerColumn),
                        s.bundleID AS bundle_id,
                        s.windowName AS window_name,
                        s.browserUrl AS browser_url,
                        ds.docid AS docid
                    FROM doc_segment ds
                    JOIN frame f ON ds.frameId = f.id
                    JOIN segment s ON s.id = f.segmentId
                    LEFT JOIN video v ON v.id = f.videoId
                    \(batchWhereClause)
                    ORDER BY f.createdAt \(sortOrderClause), f.id \(sortOrderClause)
                    LIMIT ? \(isOffsetQuery ? "OFFSET ?" : "")
                    """
                bindValuesForBatch.append(contentsOf: bindValues)
                bindValuesForBatch.append(contentsOf: cursorBindValues)
                bindValuesForBatch.append(Int64(limit))
                if let offset {
                    bindValuesForBatch.append(Int64(offset))
                }
            }

            let sql = """
                WITH batch AS MATERIALIZED (
                    \(batchSQL)
                ),
                node_candidates AS MATERIALIZED (
                    SELECT
                        b.frame_id,
                        b.docid,
                        n.id AS node_id,
                        n.nodeOrder AS node_order,
                        n.leftX AS left_x,
                        n.topY AS top_y,
                        n.width AS node_width,
                        n.height AS node_height,
                        LOWER(
                            TRIM(
                                REPLACE(
                                    REPLACE(
                                        \(visibleNodeTextSQL),
                                        char(10),
                                        ' '
                                    ),
                                    char(13),
                                    ' '
                                )
                            )
                        ) AS node_text_signature,
                        ROW_NUMBER() OVER (
                            PARTITION BY b.frame_id, b.docid
                            ORDER BY n.nodeOrder ASC
                        ) AS rn
                    FROM batch b
                    JOIN node n ON n.frameId = b.frame_id
                    JOIN searchRanking_content sc ON sc.id = b.docid
                    WHERE \(highlightMatchClause)
                ),
                first_node AS MATERIALIZED (
                    SELECT
                        frame_id,
                        docid,
                        node_id,
                        node_order,
                        left_x,
                        top_y,
                        node_width,
                        node_height,
                        node_text_signature
                    FROM node_candidates
                    WHERE rn = 1
                )
                SELECT
                    b.frame_id,
                    b.timestamp,
                    b.segment_id,
                    b.video_id,
                    b.frame_index,
                    b.video_path,
                    b.video_frame_rate,
                    b.redaction_reason,
                    b.capture_trigger,
                    b.bundle_id,
                    b.window_name,
                    b.browser_url,
                    b.docid,
                    fn.node_id,
                    fn.node_order,
                    fn.left_x,
                    fn.top_y,
                    fn.node_width,
                    fn.node_height,
                    fn.node_text_signature
                FROM batch b
                LEFT JOIN first_node fn ON fn.frame_id = b.frame_id AND fn.docid = b.docid
                ORDER BY b.timestamp \(sortOrderClause), b.frame_id \(sortOrderClause)
                """

            guard let statement = try connection.prepare(sql: sql) else {
                throw DatabaseConnectionError.statementPreparationFailed(
                    sql: sql,
                    error: "Prepared statement was nil"
                )
            }
            defer { connection.finalize(statement) }

            var bindIndex: Int32 = 1

            for value in bindValuesForBatch {
                if let stringValue = value as? String {
                    sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
                } else if let intValue = value as? Int64 {
                    sqlite3_bind_int64(statement, bindIndex, intValue)
                }
                bindIndex += 1
            }

            for term in highlightTerms {
                sqlite3_bind_text(statement, bindIndex, term, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }

            var batchRows: [FrameSearchRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let frameId = sqlite3_column_int64(statement, 0)
                let timestamp = config.parseDate(from: statement, column: 1) ?? Date()
                let segmentId = sqlite3_column_int64(statement, 2)
                let videoId = sqlite3_column_int64(statement, 3)
                let frameIndex = Int(sqlite3_column_int(statement, 4))
                let videoPath = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                let videoFrameRate: Double? = {
                    guard sqlite3_column_type(statement, 6) != SQLITE_NULL else { return nil }
                    return sqlite3_column_double(statement, 6)
                }()
                let redactionReason = sqlite3_column_text(statement, 7).map { String(cString: $0) }
                let captureTrigger = sqlite3_column_text(statement, 8)
                    .map { String(cString: $0) }
                    .flatMap(FrameCaptureTrigger.init(rawValue:))
                let appBundleID = sqlite3_column_text(statement, 9).map { String(cString: $0) }
                let windowName = sqlite3_column_text(statement, 10).map { String(cString: $0) }
                let browserUrl = sqlite3_column_text(statement, 11).map { String(cString: $0) }
                let docID = sqlite3_column_int64(statement, 12)

                let highlightNode: SearchResult.HighlightNode?
                if sqlite3_column_type(statement, 13) != SQLITE_NULL {
                    let nodeID = sqlite3_column_int64(statement, 13)
                    let nodeOrder = Int(sqlite3_column_int(statement, 14))
                    let x = sqlite3_column_double(statement, 15)
                    let y = sqlite3_column_double(statement, 16)
                    let width = sqlite3_column_double(statement, 17)
                    let height = sqlite3_column_double(statement, 18)
                    highlightNode = SearchResult.HighlightNode(
                        nodeID: nodeID,
                        nodeOrder: nodeOrder,
                        x: x,
                        y: y,
                        width: width,
                        height: height
                    )
                } else {
                    highlightNode = nil
                }
                let highlightTextSignature = sqlite3_column_text(statement, 19).map { String(cString: $0) }

                batchRows.append(
                    FrameSearchRow(
                        frameId: frameId,
                        timestamp: timestamp,
                        segmentId: segmentId,
                        videoId: videoId,
                        frameIndex: frameIndex,
                        videoPath: videoPath,
                        videoFrameRate: videoFrameRate,
                        redactionReason: redactionReason,
                        captureTrigger: captureTrigger,
                        appBundleID: appBundleID,
                        windowName: windowName,
                        browserUrl: browserUrl,
                        docID: docID,
                        highlightNode: highlightNode,
                        highlightTextSignature: highlightTextSignature
                    )
                )
            }

            return batchRows
        }

        let frameCursor = sourceCursor.map { FrameCursor(timestamp: $0.timestamp, frameId: $0.frameID) }
        let batchFetchLimit = max(query.limit, Self.searchAllRawBatchSize)
        let batchOffset: Int? = frameCursor == nil ? normalizedOffset : nil
        let batch = try fetchFrameBatch(limit: batchFetchLimit, offset: batchOffset, cursor: frameCursor)
        let sourceRowsFetched = batch.count
        var dedupedRows: [FrameSearchRow] = []
        var recentAnchors: [SearchDedupeMatchBox] = []
        var recentWindowNameSignatures: [String] = []

        for row in batch {
            let currentWindowNameSignature = normalizedWindowNameSignature(row.windowName)
            if let highlightNode = row.highlightNode {
                let currentAnchor = SearchDedupeMatchBox(
                    label: "highlight",
                    textSignature: normalizedSearchDedupeTextSignature(row.highlightTextSignature) ?? "",
                    nodeOrder: highlightNode.nodeOrder,
                    xBin: quantizedNodeBin(highlightNode.x),
                    yBin: quantizedNodeBin(highlightNode.y),
                    wBin: max(1, quantizedNodeBin(highlightNode.width)),
                    hBin: max(1, quantizedNodeBin(highlightNode.height))
                )
                if recentAnchors.contains(where: { areConsecutiveDedupeBoxesSimilar($0, currentAnchor) }) {
                    continue
                }
                recentAnchors.append(currentAnchor)
                if recentAnchors.count > Self.searchDedupeLookbackWindow {
                    recentAnchors.removeFirst(recentAnchors.count - Self.searchDedupeLookbackWindow)
                }
            } else {
                // No highlight node available; keep row and reset positional streak.
                recentAnchors.removeAll(keepingCapacity: true)
            }

            if let currentWindowNameSignature,
               recentWindowNameSignatures.contains(where: { areConsecutiveWindowNamesSimilar($0, currentWindowNameSignature) }) {
                continue
            }

            dedupedRows.append(row)
            if let currentWindowNameSignature {
                recentWindowNameSignatures.append(currentWindowNameSignature)
                if recentWindowNameSignatures.count > Self.searchDedupeLookbackWindow {
                    recentWindowNameSignatures.removeFirst(recentWindowNameSignatures.count - Self.searchDedupeLookbackWindow)
                }
            } else {
                recentWindowNameSignatures.removeAll(keepingCapacity: true)
            }
        }
        let frameResults = dedupedRows

        let nextSourceCursor: SearchSourceCursor?
        if sourceRowsFetched == batchFetchLimit, let lastFetched = batch.last {
            nextSourceCursor = SearchSourceCursor(timestamp: lastFetched.timestamp, frameID: lastFetched.frameId)
        } else {
            nextSourceCursor = nil
        }
        let nextCursor: SearchPageCursor? = {
            guard let nextSourceCursor else { return nil }
            if source == .rewind {
                return SearchPageCursor(rewind: nextSourceCursor)
            }
            return SearchPageCursor(native: nextSourceCursor)
        }()

        guard !frameResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], searchTimeMs: elapsed, nextCursor: nextCursor)
        }

        var results: [SearchResult] = []

        for frame in frameResults {
            let appBundleID = frame.appBundleID
            let windowName = frame.windowName
            let browserUrl = frame.browserUrl
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
                    redactionReason: frame.redactionReason,
                    captureTrigger: frame.captureTrigger,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: frame.segmentId),
                videoID: VideoSegmentID(value: frame.videoId),
                frameIndex: frame.frameIndex,
                videoPath: frame.videoPath,
                videoFrameRate: frame.videoFrameRate,
                source: source,
                highlightNode: frame.highlightNode
            )

            results.append(result)
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        return SearchResults(query: query, results: results, searchTimeMs: elapsed, nextCursor: nextCursor)
    }

    private struct FTSQueryComponents {
        let includeParts: [String]
        let excludeTerms: [String]
    }

    private static func parseFTSQueryComponents(_ text: String) -> FTSQueryComponents {
        let tokens = tokenizeSearchQuery(text)
        var includeParts: [String] = []
        var excludeTerms: [String] = []

        for token in tokens {
            if token == "-" {
                continue
            }

            if token.hasPrefix("-") && token.count > 1 {
                let rawExcluded = String(token.dropFirst())
                if rawExcluded.hasPrefix("\""), rawExcluded.hasSuffix("\""), rawExcluded.count > 1 {
                    let phrase = sanitizeFTSTerm(String(rawExcluded.dropFirst().dropLast()))
                    if !phrase.isEmpty {
                        excludeTerms.append("\"\(phrase)\"")
                    }
                } else {
                    let term = sanitizeFTSTerm(rawExcluded)
                    if !term.isEmpty {
                        excludeTerms.append("\"\(term)\"")
                    }
                }
                continue
            }

            if token.hasPrefix("\""), token.hasSuffix("\""), token.count > 1 {
                let phrase = sanitizeFTSTerm(String(token.dropFirst().dropLast()))
                if !phrase.isEmpty {
                    includeParts.append("\"\(phrase)\"")
                }
            } else {
                let term = sanitizeFTSTerm(token)
                if !term.isEmpty {
                    includeParts.append(formatUnquotedTerm(term))
                }
            }
        }

        return FTSQueryComponents(includeParts: includeParts, excludeTerms: excludeTerms)
    }

    private static func buildFTSQuery(_ text: String) -> String {
        buildFTSQuery(parseFTSQueryComponents(text))
    }

    private static func buildFTSQuery(_ components: FTSQueryComponents) -> String {
        // Exclusion-only queries are invalid in FTS syntax (`NOT x` cannot stand alone).
        // Keep this path deterministic and return no rows.
        guard !components.includeParts.isEmpty else {
            return "\"__retrace_no_match__\""
        }

        let excludeParts = components.excludeTerms.map { "NOT \($0)" }
        return (components.includeParts + excludeParts).joined(separator: " ")
    }

    /// Tokenize query while preserving quoted phrases and handling `-"phrase"` as one token.
    private static func tokenizeSearchQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                if inQuotes {
                    current.append(char)
                    tokens.append(current)
                    current = ""
                    inQuotes = false
                } else {
                    if current == "-" {
                        current.append(char)
                        inQuotes = true
                        continue
                    }
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                    current.append(char)
                    inQuotes = true
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Restrict FTS MATCH to content columns only (exclude window title metadata).
    private static func scopeToSearchableTextColumns(_ components: FTSQueryComponents) -> String {
        guard !components.includeParts.isEmpty else {
            return "\"__retrace_no_match__\""
        }

        let includeClause = components.includeParts.joined(separator: " ")
        var parts = ["((text:(\(includeClause))) OR (otherText:(\(includeClause))))"]
        for excludedTerm in components.excludeTerms {
            parts.append("NOT text:(\(excludedTerm))")
            parts.append("NOT otherText:(\(excludedTerm))")
        }
        return parts.joined(separator: " ")
    }

    private static let encodedMetadataFilterPrefix = "__retrace_meta_filter_v1__"

    private struct EncodedMetadataFilterPayload: Codable {
        let includeTerms: [String]?
        let excludeTerms: [String]?
        // Legacy fields for backward compatibility.
        let mode: AppFilterMode?
        let terms: [String]?
    }

    private struct ParsedMetadataStringFilter {
        let includeTerms: [String]
        let excludeTerms: [String]

        var hasActiveFilters: Bool {
            !includeTerms.isEmpty || !excludeTerms.isEmpty
        }
    }

    private static func decodeMetadataStringFilter(_ rawValue: String?) -> ParsedMetadataStringFilter {
        guard let rawValue else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        guard trimmed.hasPrefix(encodedMetadataFilterPrefix) else {
            let normalized = normalizedMetadataStringFilterTerms([trimmed])
            return ParsedMetadataStringFilter(includeTerms: normalized, excludeTerms: [])
        }

        let encodedPayload = String(trimmed.dropFirst(encodedMetadataFilterPrefix.count))
        guard let data = Data(base64Encoded: encodedPayload),
              let payload = try? JSONDecoder().decode(EncodedMetadataFilterPayload.self, from: data) else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        let normalizedIncludeTerms = normalizedMetadataStringFilterTerms(payload.includeTerms ?? [])
        var normalizedExcludeTerms = normalizedMetadataStringFilterTerms(payload.excludeTerms ?? [])
        if !normalizedIncludeTerms.isEmpty || !normalizedExcludeTerms.isEmpty {
            let includeKeys = Set(normalizedIncludeTerms.map { $0.lowercased() })
            normalizedExcludeTerms.removeAll { includeKeys.contains($0.lowercased()) }
            return ParsedMetadataStringFilter(
                includeTerms: normalizedIncludeTerms,
                excludeTerms: normalizedExcludeTerms
            )
        }

        let normalizedLegacyTerms = normalizedMetadataStringFilterTerms(payload.terms ?? [])
        if payload.mode == .exclude {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: normalizedLegacyTerms)
        }
        return ParsedMetadataStringFilter(includeTerms: normalizedLegacyTerms, excludeTerms: [])
    }

    private static func appendMetadataStringFilter(
        columnName: String,
        parsedFilter: ParsedMetadataStringFilter,
        whereConditions: inout [String],
        bindValues: inout [String]
    ) {
        for term in parsedFilter.includeTerms {
            guard let predicate = metadataStringFilterPredicate(columnName: columnName, term: term, negate: false) else {
                continue
            }
            whereConditions.append("(\(predicate.clause))")
            bindValues.append(contentsOf: predicate.bindValues)
        }

        for term in parsedFilter.excludeTerms {
            guard let predicate = metadataStringFilterPredicate(columnName: columnName, term: term, negate: true) else {
                continue
            }
            whereConditions.append("(\(predicate.clause))")
            bindValues.append(contentsOf: predicate.bindValues)
        }
    }

    private static func appendMetadataStringFilter(
        columnName: String,
        parsedFilter: ParsedMetadataStringFilter,
        whereConditions: inout [String],
        bindValues: inout [Any]
    ) {
        var stringBindValues: [String] = []
        appendMetadataStringFilter(
            columnName: columnName,
            parsedFilter: parsedFilter,
            whereConditions: &whereConditions,
            bindValues: &stringBindValues
        )
        bindValues.append(contentsOf: stringBindValues)
    }

    private static func metadataStringFilterPredicate(
        columnName: String,
        term: String,
        negate: Bool
    ) -> (clause: String, bindValues: [String])? {
        guard let parsed = parsedMetadataStringFilterTerm(term) else { return nil }

        let op = negate ? "NOT LIKE" : "LIKE"
        switch parsed {
        case .exactPhrase(let phrase):
            return (
                clause: "COALESCE(\(columnName), '') \(op) ?",
                bindValues: ["%\(phrase)%"]
            )
        case .tokens(let tokens):
            // Exclusion must reject rows matching any token, so combine NOT LIKE terms with AND.
            let tokenJoiner = negate ? " AND " : " OR "
            let clause = tokens.map { _ in
                "COALESCE(\(columnName), '') \(op) ?"
            }.joined(separator: tokenJoiner)
            let bindValues = tokens.map { "%\($0)%" }
            return (clause: clause, bindValues: bindValues)
        }
    }

    private enum ParsedMetadataStringFilterTerm {
        case exactPhrase(String)
        case tokens([String])
    }

    private static func parsedMetadataStringFilterTerm(_ term: String) -> ParsedMetadataStringFilterTerm? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let phrase = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return nil }
            return .exactPhrase(phrase)
        }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return .tokens(tokens)
    }

    private static func normalizedMetadataStringFilterTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let normalized = normalizedMetadataStringFilterTerm(term) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(normalized)
            }
        }

        return normalizedTerms
    }

    private static func normalizedMetadataStringFilterTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Remove characters that have special meaning in FTS query syntax.
    private static func sanitizeFTSTerm(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    /// For unquoted terms, avoid prefix expansion on stopwords and very short tokens.
    /// This keeps terms like "a" as exact-token matches instead of broad "a*" prefix matches.
    private static func formatUnquotedTerm(_ term: String) -> String {
        if shouldUseExactMatch(term) {
            return "\"\(term)\""
        }
        return "\"\(term)\"*"
    }

    private static func shouldUseExactMatch(_ term: String) -> Bool {
        if term.count <= 2 {
            return true
        }
        return Self.exactMatchStopwords.contains(term.lowercased())
    }

    private enum SearchDedupeTermMatchMode {
        case exactWord
        case wordPrefix
    }

    private enum SearchDedupeToken {
        case term(String, mode: SearchDedupeTermMatchMode)
        case phrase(String)

        var signatureLabel: String {
            switch self {
            case .term(let value, _):
                return value
            case .phrase(let value):
                return "\"\(value)\""
            }
        }

        var dedupeKey: String {
            switch self {
            case .term(let value, let mode):
                switch mode {
                case .exactWord:
                    return "te:\(value)"
                case .wordPrefix:
                    return "tp:\(value)"
                }
            case .phrase(let value):
                return "p:\(value)"
            }
        }

        var matchingTerm: String {
            switch self {
            case .term(let value, _):
                return value
            case .phrase(let value):
                return value
            }
        }
    }

    private static func parseSearchDedupeTokens(_ query: String) -> [SearchDedupeToken] {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        var tokens: [SearchDedupeToken] = []
        var seenKeys = Set<String>()

        func appendToken(_ token: SearchDedupeToken) {
            if seenKeys.insert(token.dedupeKey).inserted {
                tokens.append(token)
            }
        }

        for token in tokenizeSearchQuery(normalizedQuery) {
            if token == "-" {
                continue
            }

            if token.hasPrefix("-"), token.count > 1 {
                // Excluded query terms should not drive highlight matching / dedupe anchors.
                continue
            }

            if token.hasPrefix("\""), token.hasSuffix("\""), token.count > 1 {
                let phrase = sanitizeFTSTerm(String(token.dropFirst().dropLast()))
                if !phrase.isEmpty {
                    appendToken(.phrase(phrase))
                }
                continue
            }

            let term = sanitizeFTSTerm(token)
            guard !term.isEmpty else { continue }
            let mode: SearchDedupeTermMatchMode = shouldUseExactMatch(term) ? .exactWord : .wordPrefix
            appendToken(.term(term, mode: mode))
        }

        return tokens
    }

    private struct SearchDedupeMatchBox: Hashable {
        let label: String
        let textSignature: String
        let nodeOrder: Int
        let xBin: Int
        let yBin: Int
        let wBin: Int
        let hBin: Int

        var minX: Double { Double(xBin) / 1000.0 }
        var minY: Double { Double(yBin) / 1000.0 }
        var width: Double { max(0.0, Double(wBin) / 1000.0) }
        var height: Double { max(0.0, Double(hBin) / 1000.0) }
        var maxX: Double { minX + width }
        var maxY: Double { minY + height }
        var centerX: Double { minX + (width / 2.0) }
        var centerY: Double { minY + (height / 2.0) }
    }

    private static func areConsecutiveDedupeBoxesSimilar(
        _ lhs: SearchDedupeMatchBox,
        _ rhs: SearchDedupeMatchBox
    ) -> Bool {
        guard lhs.label == rhs.label else {
            return false
        }

        let widthRatio = ratioSimilarity(lhs.width, rhs.width)
        let heightRatio = ratioSimilarity(lhs.height, rhs.height)
        let sameText = !lhs.textSignature.isEmpty && lhs.textSignature == rhs.textSignature
        let minWidthRatio = sameText ? Self.searchDedupeSameTextMinWidthRatio : Self.searchDedupeScrollShiftMinWidthRatio
        let minHeightRatio = sameText ? Self.searchDedupeSameTextMinHeightRatio : Self.searchDedupeScrollShiftMinHeightRatio
        let maxXDelta = sameText ? Self.searchDedupeSameTextMaxXDelta : Self.searchDedupeDifferentTextMaxXDelta

        let xCenterDelta = abs(lhs.centerX - rhs.centerX)
        if xCenterDelta <= maxXDelta &&
            widthRatio >= minWidthRatio &&
            heightRatio >= minHeightRatio {
            return true
        }

        return false
    }

    private static func ratioSimilarity(_ lhs: Double, _ rhs: Double) -> Double {
        let maxValue = max(lhs, rhs)
        guard maxValue > 0.0 else { return 0.0 }
        return min(lhs, rhs) / maxValue
    }

    private static func normalizedSearchDedupeTextSignature(_ text: String?) -> String? {
        guard let raw = text?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedWindowNameSignature(_ windowName: String?) -> String? {
        guard let raw = windowName?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        var normalized = ""
        normalized.reserveCapacity(raw.count)

        for scalar in raw.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            }
        }

        return normalized.isEmpty ? nil : normalized
    }

    private static func areConsecutiveWindowNamesSimilar(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs
    }

    private static func quantizedNodeBin(_ value: Double) -> Int {
        Int((value * 1000.0).rounded())
    }

    /// Relevant-mode cursor encoding.
    /// We store rank in the cursor timestamp field so we can keyset-page on (rank, frameID).
    private static func encodeRelevantCursorRank(_ rank: Double) -> Date {
        Date(timeIntervalSince1970: rank)
    }

    /// Decode relevant cursor from shared SearchSourceCursor.
    /// Ignore cursors that look like wall-clock timestamps from other modes.
    private static func decodeRelevantCursor(_ sourceCursor: SearchSourceCursor?) -> (rank: Double, frameId: Int64)? {
        guard let sourceCursor else { return nil }
        let rank = sourceCursor.timestamp.timeIntervalSince1970
        guard rank.isFinite, abs(rank) < 1_000_000 else { return nil }
        return (rank: rank, frameId: sourceCursor.frameID)
    }

    /// Build SQL clause for app filtering (IN or NOT IN based on filter mode)
    /// Returns the SQL clause like "s.bundleID IN (?, ?, ?)" or "s.bundleID NOT IN (?, ?, ?)"
    private static func buildAppFilterClause(apps: Set<String>, mode: AppFilterMode, tableAlias: String = "s") -> String {
        let placeholders = apps.map { _ in "?" }.joined(separator: ", ")
        let operator_ = mode == .include ? "IN" : "NOT IN"
        return "\(tableAlias).bundleID \(operator_) (\(placeholders))"
    }

    private struct FrameFilterQueryComponents {
        let combinedCTE: String
        let tagJoin: String
        let whereClauses: [String]
        let includedTagIDs: [Int64]
        let appBundleIDs: [String]
        let metadataBindValues: [String]
        let dateRangeBounds: [Date]
        let sourceBoundaryBounds: [Date]
        let excludedTagIDs: [Int64]
        let hiddenTagID: Int64?
    }

    private static func buildFrameFilterQueryComponents(
        filters: FilterCriteria,
        config: DatabaseConfig,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool,
        includeSourceBoundary: Bool = true
    ) -> FrameFilterQueryComponents {
        let shouldApplyTagFilters = !isRewindDatabase
        let orderedTagIDs = resolvedOrderedTagIDs(
            filters: filters,
            hiddenTagId: hiddenTagId,
            shouldApplyTagFilters: shouldApplyTagFilters
        )
        let appBundleIDs = filters.selectedApps?.sorted() ?? []
        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)

        let tagFilterMode = filters.tagFilterMode
        let hasTagFilter = !orderedTagIDs.isEmpty
        let includedTagIDs: [Int64]
        let excludedTagIDs: [Int64]
        let combinedCTE: String
        let tagJoin: String

        if hasTagFilter, tagFilterMode == .include {
            let tagPlaceholders = orderedTagIDs.map { _ in "?" }.joined(separator: ", ")
            combinedCTE = """
                WITH tagged_segments AS (
                    SELECT DISTINCT segmentId
                    FROM segment_tag
                    WHERE tagId IN (\(tagPlaceholders))
                )
                """
            tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
            includedTagIDs = orderedTagIDs
            excludedTagIDs = []
        } else {
            combinedCTE = ""
            tagJoin = ""
            includedTagIDs = []
            excludedTagIDs = hasTagFilter && tagFilterMode == .exclude ? orderedTagIDs : []
        }

        var whereClauses: [String] = []
        var metadataBindValues: [String] = []

        if !appBundleIDs.isEmpty {
            whereClauses.append(Self.buildAppFilterClause(apps: Set(appBundleIDs), mode: filters.appFilterMode))
        }

        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        let sourceBoundaryBounds: [Date]
        if includeSourceBoundary {
            let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
            if let sourceBoundaryClause = sourceBoundaryFilter.clause {
                whereClauses.append(sourceBoundaryClause)
            }
            sourceBoundaryBounds = sourceBoundaryFilter.bindValues
        } else {
            sourceBoundaryBounds = []
        }

        if !excludedTagIDs.isEmpty {
            let tagPlaceholders = excludedTagIDs.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        let hiddenTagID: Int64?
        if shouldApplyTagFilters, filters.hiddenFilter == .hide, let hiddenTagId {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
            hiddenTagID = hiddenTagId
        } else {
            hiddenTagID = nil
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        return FrameFilterQueryComponents(
            combinedCTE: combinedCTE,
            tagJoin: tagJoin,
            whereClauses: whereClauses,
            includedTagIDs: includedTagIDs,
            appBundleIDs: appBundleIDs,
            metadataBindValues: metadataBindValues,
            dateRangeBounds: dateRangeFilter.bindValues,
            sourceBoundaryBounds: sourceBoundaryBounds,
            excludedTagIDs: excludedTagIDs,
            hiddenTagID: hiddenTagID
        )
    }

    private static func resolvedOrderedTagIDs(
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        shouldApplyTagFilters: Bool
    ) -> [Int64] {
        guard shouldApplyTagFilters else { return [] }

        var tagsToFilter = filters.selectedTags ?? Set<Int64>()
        if let hiddenTagId {
            switch filters.hiddenFilter {
            case .hide:
                break
            case .onlyHidden:
                tagsToFilter = [hiddenTagId]
            case .showAll:
                break
            }
        }

        return tagsToFilter.sorted()
    }

    @discardableResult
    private static func bindFrameFilterCTEValues(
        _ components: FrameFilterQueryComponents,
        to statement: OpaquePointer,
        startingAt bindIndex: Int32
    ) -> Int32 {
        var currentBindIndex = bindIndex
        for tagId in components.includedTagIDs {
            sqlite3_bind_int64(statement, currentBindIndex, tagId)
            currentBindIndex += 1
        }
        return currentBindIndex
    }

    @discardableResult
    private static func bindFrameFilterWhereValues(
        _ components: FrameFilterQueryComponents,
        to statement: OpaquePointer,
        config: DatabaseConfig,
        startingAt bindIndex: Int32
    ) -> Int32 {
        var currentBindIndex = bindIndex

        for app in components.appBundleIDs {
            sqlite3_bind_text(statement, currentBindIndex, (app as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        for stringValue in components.metadataBindValues {
            sqlite3_bind_text(statement, currentBindIndex, (stringValue as NSString).utf8String, -1, nil)
            currentBindIndex += 1
        }

        for date in components.dateRangeBounds {
            config.bindDate(date, to: statement, at: currentBindIndex)
            currentBindIndex += 1
        }

        for date in components.sourceBoundaryBounds {
            config.bindDate(date, to: statement, at: currentBindIndex)
            currentBindIndex += 1
        }

        for tagId in components.excludedTagIDs {
            sqlite3_bind_int64(statement, currentBindIndex, tagId)
            currentBindIndex += 1
        }

        if let hiddenTagID = components.hiddenTagID {
            sqlite3_bind_int64(statement, currentBindIndex, hiddenTagID)
            currentBindIndex += 1
        }

        return currentBindIndex
    }

    /// Build SQL clause for comment-presence filtering.
    /// Returns nil when no filtering is required.
    private static func buildCommentFilterClause(
        _ filter: CommentFilter,
        isRewindDatabase: Bool,
        segmentIDExpression: String
    ) -> String? {
        switch filter {
        case .allFrames:
            return nil
        case .commentsOnly:
            if isRewindDatabase {
                // Rewind does not have comment-link data.
                return "1 = 0"
            }
            return """
                EXISTS (
                    SELECT 1 FROM segment_comment_link scl
                    WHERE scl.segmentId = \(segmentIDExpression)
                )
                """
        case .noComments:
            if isRewindDatabase {
                // Rewind has no comments, so all rows are "no comments".
                return nil
            }
            return """
                NOT EXISTS (
                    SELECT 1 FROM segment_comment_link scl
                    WHERE scl.segmentId = \(segmentIDExpression)
                )
                """
        }
    }

    private func deleteFrames(frameIDs: [FrameID], connection: DatabaseConnection) throws {
        guard !frameIDs.isEmpty else { return }
        guard let db = connection.getConnection() else {
            throw DataAdapterError.databaseError("Database connection unavailable")
        }
        _ = try FrameQueries.delete(db: db, frameIDs: frameIDs)
    }

    // MARK: - Row Parsing

    private static func parseFrameWithVideoInfo(statement: OpaquePointer, config: DatabaseConfig) throws -> FrameWithVideoInfo {
        let id = FrameID(value: sqlite3_column_int64(statement, 0))

        guard let timestamp = config.parseDate(from: statement, column: 1) else {
            throw DataAdapterError.parseFailed
        }

        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        let encodedAt = config.parseDate(from: statement, column: 5)
        let processingStatus = Int(sqlite3_column_int(statement, 6))

        let redactionReason = Self.getTextOrNil(statement, 7)
        let captureTrigger = Self.getTextOrNil(statement, 8).flatMap(FrameCaptureTrigger.init(rawValue:))
        let bundleID = Self.getTextOrNil(statement, 9) ?? ""
        let windowName = Self.getTextOrNil(statement, 10)
        let browserUrl = Self.getTextOrNil(statement, 11)
        let mousePosition = Self.decodeStoredPoint(Self.getTextOrNil(statement, 12))
        let scrollY = Self.decodeStoredPoint(Self.getTextOrNil(statement, 13))?.y
        let videoCurrentTime = sqlite3_column_type(statement, 14) != SQLITE_NULL ? sqlite3_column_double(statement, 14) : nil

        let videoPath = Self.getTextOrNil(statement, 15)
        let frameRate = sqlite3_column_type(statement, 16) != SQLITE_NULL ? sqlite3_column_double(statement, 16) : nil
        let width = sqlite3_column_type(statement, 17) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 17)) : nil
        let height = sqlite3_column_type(statement, 18) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 18)) : nil

        let metadata = FrameMetadata(
            appBundleID: bundleID.isEmpty ? nil : bundleID,
            appName: bundleID.components(separatedBy: ".").last,
            windowName: windowName,
            browserURL: browserUrl,
            redactionReason: redactionReason,
            captureTrigger: captureTrigger,
            displayID: 0,
            mousePosition: mousePosition.map { CGPoint(x: $0.x, y: $0.y) }
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodedAt: encodedAt,
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

        return FrameWithVideoInfo(
            frame: frame,
            videoInfo: videoInfo,
            processingStatus: processingStatus,
            videoCurrentTime: videoCurrentTime,
            scrollY: scrollY
        )
    }

    private static func parseSegment(statement: OpaquePointer, config: DatabaseConfig) throws -> Segment {
        let id = SegmentID(value: sqlite3_column_int64(statement, 0))
        let bundleID = Self.getTextOrNil(statement, 1) ?? ""

        guard let startDate = config.parseDate(from: statement, column: 2),
              let endDate = config.parseDate(from: statement, column: 3) else {
            throw DataAdapterError.parseFailed
        }

        let windowName = Self.getTextOrNil(statement, 4)
        let browserUrl = Self.getTextOrNil(statement, 5)
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
        let nodeOrder = Int(sqlite3_column_int(statement, 1))
        let leftX = sqlite3_column_double(statement, 4)
        let topY = sqlite3_column_double(statement, 5)
        let width = sqlite3_column_double(statement, 6)
        let height = sqlite3_column_double(statement, 7)
        let isRedacted = sqlite3_column_int(statement, 8) != 0

        let text = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""
        let encryptedText = sqlite3_column_text(statement, 10).map { String(cString: $0) }

        // Column 11: frameId for debugging
        let frameId = sqlite3_column_int64(statement, 11)

        return OCRNodeWithText(
            id: id,
            nodeOrder: nodeOrder,
            frameId: frameId,
            x: leftX,
            y: topY,
            width: width,
            height: height,
            text: text,
            encryptedText: encryptedText,
            isRedacted: isRedacted
        )
    }

    private static func getTextOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Combined Statistics (Retrace + Rewind)

    /// Get distinct dates that have frames from both Retrace and Rewind sources.
    /// When active filters are provided, only dates matching those filters are returned.
    /// Returns dates sorted in descending order (newest first).
    public func getDistinctDates(filters: FilterCriteria? = nil) async throws -> [Date] {
        if let filters, filters.hasActiveFilters {
            return try await getDistinctDatesWithFilters(filters)
        }

        var allDates = Set<Date>()
        let calendar = Calendar.current

        // Get dates from Retrace
        let retraceDates = try await withNativeRead(operation: "data_adapter.distinct_dates.native") { connection, config in
            try Self.queryDistinctDates(connection: connection, config: config)
        }
        for date in retraceDates {
            allDates.insert(calendar.startOfDay(for: date))
        }

        // Get dates from Rewind if connected
        if hasRewindReadSource {
            let rewindDates = try await withRewindRead(operation: "data_adapter.distinct_dates.rewind") { connection, config in
                try Self.queryDistinctDates(connection: connection, config: config)
            }
            for date in rewindDates {
                allDates.insert(calendar.startOfDay(for: date))
            }
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    private func getDistinctDatesWithFilters(_ filters: FilterCriteria) async throws -> [Date] {
        var allDates = Set<Date>()
        let calendar = Calendar.current
        let hiddenTagId = cachedHiddenTagId

        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
            filters.selectedSources?.contains(.rewind) == false
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let effectiveDateRanges = filters.effectiveDateRanges
        let hasRewindDateOverlap = hasDateRangeIntersectingRewind(effectiveDateRanges)

        if !excludeRetrace {
            let retraceDates = try await withNativeRead(operation: "data_adapter.distinct_dates.filtered.native") { connection, config in
                try Self.queryDistinctDatesWithFilters(
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            for date in retraceDates {
                allDates.insert(calendar.startOfDay(for: date))
            }
        }

        if !excludeRewind, !hasRetraceOnlyFilters, hasRewindDateOverlap, hasRewindReadSource {
            let rewindDates = try await withRewindRead(operation: "data_adapter.distinct_dates.filtered.rewind") { connection, config in
                try Self.queryDistinctDatesWithFilters(
                    connection: connection,
                    config: config,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            for date in rewindDates {
                allDates.insert(calendar.startOfDay(for: date))
            }
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    /// Query distinct dates from a specific connection
    private static func queryDistinctDates(connection: DatabaseConnection, config: DatabaseConfig) throws -> [Date] {
        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "createdAt")
        let whereClause = sourceBoundaryFilter.clause.map { "WHERE \($0)" } ?? ""

        let sql: String
        if config.dateFormatter == nil {
            sql = """
                SELECT MIN(createdAt) as dayTimestamp
                FROM frame
                \(whereClause)
                GROUP BY date(createdAt / 1000, 'unixepoch', 'localtime')
                ORDER BY dayTimestamp DESC
                """
        } else {
            sql = """
                SELECT MIN(createdAt) as dayTimestamp
                FROM frame
                \(whereClause)
                GROUP BY date(createdAt, 'localtime')
                ORDER BY dayTimestamp DESC
                """
        }

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var bindIndex = 1
        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let date = config.parseDate(from: statement, column: 0) else { continue }
            dates.append(date)
        }

        return dates
    }

    private static func queryDistinctDatesWithFilters(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool
    ) throws -> [Date] {
        let groupExpression = config.dateFormatter == nil
            ? "date(f.createdAt / 1000, 'unixepoch', 'localtime')"
            : "date(f.createdAt, 'localtime')"
        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase
        )
        let whereClause = filterComponents.whereClauses.isEmpty
            ? ""
            : "WHERE " + filterComponents.whereClauses.joined(separator: " AND ")

        let sql = """
            \(filterComponents.combinedCTE)
            SELECT MIN(f.createdAt) AS dayTimestamp
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            \(whereClause)
            GROUP BY \(groupExpression)
            ORDER BY dayTimestamp DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1
        bindIndex = Self.bindFrameFilterCTEValues(
            filterComponents,
            to: statement,
            startingAt: bindIndex
        )
        _ = Self.bindFrameFilterWhereValues(
            filterComponents,
            to: statement,
            config: config,
            startingAt: bindIndex
        )

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let date = config.parseDate(from: statement, column: 0) else { continue }
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
        guard let config = rewindConfig else { return [] }
        return try Self.queryDistinctDates(connection: rewind, config: config)
    }

    /// Get Rewind storage root path for storage calculations (returns nil if Rewind not connected)
    public var rewindStorageRootPath: String? {
        guard rewindConnection != nil else { return nil }
        return AppPaths.expandedRewindStorageRoot
    }

    // MARK: - Calendar Hours Query

    /// Get distinct hours for a specific date that have frames.
    /// When active filters are provided, only hours matching those filters are returned.
    /// Queries both databases and merges results to show all available hours.
    public func getDistinctHoursForDate(_ date: Date, filters: FilterCriteria? = nil) async throws -> [Date] {
        if let filters, filters.hasActiveFilters {
            return try await getDistinctHoursForDateWithFilters(date, filters: filters)
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var allHours = Set<Date>()

        // Query Retrace database
        let retraceHours = try await withNativeRead(operation: "data_adapter.distinct_hours.native") { connection, config in
            try Self.queryDistinctHoursRetrace(
                connection: connection,
                config: config,
                startOfDay: startOfDay,
                endOfDay: endOfDay
            )
        }
        allHours.formUnion(retraceHours)

        // Query Rewind database if connected
        if hasRewindReadSource {
            let rewindHours = try await withRewindRead(operation: "data_adapter.distinct_hours.rewind") { connection, config in
                try Self.queryDistinctHoursRewind(
                    connection: connection,
                    config: config,
                    startOfDay: startOfDay,
                    endOfDay: endOfDay
                )
            }
            allHours.formUnion(rewindHours)
        }

        // Return sorted by time (earliest first)
        return Array(allHours).sorted()
    }

    private func getDistinctHoursForDateWithFilters(_ date: Date, filters: FilterCriteria) async throws -> [Date] {
        var allHours = Set<Date>()
        let hiddenTagId = cachedHiddenTagId

        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
            filters.selectedSources?.contains(.rewind) == false
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let effectiveDateRanges = filters.effectiveDateRanges
        let hasRewindDateOverlap = hasDateRangeIntersectingRewind(effectiveDateRanges)

        if !excludeRetrace {
            let retraceHours = try await withNativeRead(operation: "data_adapter.distinct_hours.filtered.native") { connection, config in
                try Self.queryDistinctHoursForDateWithFilters(
                    connection: connection,
                    config: config,
                    date: date,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: false
                )
            }
            allHours.formUnion(retraceHours)
        }

        if !excludeRewind, !hasRetraceOnlyFilters, hasRewindDateOverlap, hasRewindReadSource {
            let rewindHours = try await withRewindRead(operation: "data_adapter.distinct_hours.filtered.rewind") { connection, config in
                try Self.queryDistinctHoursForDateWithFilters(
                    connection: connection,
                    config: config,
                    date: date,
                    filters: filters,
                    hiddenTagId: hiddenTagId,
                    isRewindDatabase: true
                )
            }
            allHours.formUnion(rewindHours)
        }

        return Array(allHours).sorted()
    }

    /// Query distinct hours from Retrace database (INTEGER timestamps in milliseconds)
    /// Returns the actual first frame timestamp for each hour (not normalized to :00:00)
    /// so that navigation can find frames around that time
    private static func queryDistinctHoursRetrace(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        let effectiveStartOfDay = config.applyLowerBound(to: startOfDay)
        let effectiveEndOfDay = config.applyCutoff(to: endOfDay)
        guard effectiveStartOfDay < effectiveEndOfDay else { return [] }

        let startMs = Int64(effectiveStartOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(effectiveEndOfDay.timeIntervalSince1970 * 1000)

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
    private static func queryDistinctHoursRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        guard let formatter = config.dateFormatter else {
            return try queryDistinctHoursRetrace(
                connection: connection,
                config: config,
                startOfDay: startOfDay,
                endOfDay: endOfDay
            )
        }

        let effectiveStartOfDay = config.applyLowerBound(to: startOfDay)
        let effectiveEndOfDay = config.applyCutoff(to: endOfDay)
        guard effectiveStartOfDay < effectiveEndOfDay else { return [] }

        let startISO = formatter.string(from: effectiveStartOfDay)
        let endISO = formatter.string(from: effectiveEndOfDay)

        // Rewind stores TEXT timestamps like '2025-12-18T22:00:02.655'
        // Extract hour using substr (faster than strftime on TEXT)
        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY strftime('%H', createdAt, 'localtime')
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

    private static func queryDistinctHoursForDateWithFilters(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        date: Date,
        filters: FilterCriteria,
        hiddenTagId: Int64?,
        isRewindDatabase: Bool
    ) throws -> [Date] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        let groupExpression = config.dateFormatter == nil
            ? "strftime('%H', f.createdAt / 1000, 'unixepoch', 'localtime')"
            : "strftime('%H', f.createdAt, 'localtime')"
        let filterComponents = Self.buildFrameFilterQueryComponents(
            filters: filters,
            config: config,
            hiddenTagId: hiddenTagId,
            isRewindDatabase: isRewindDatabase
        )
        var whereClauses = filterComponents.whereClauses
        whereClauses.append("f.createdAt >= ?")
        whereClauses.append("f.createdAt < ?")
        let whereClause = "WHERE " + whereClauses.joined(separator: " AND ")

        let sql = """
            \(filterComponents.combinedCTE)
            SELECT MIN(f.createdAt) AS hourTimestamp
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(filterComponents.tagJoin)
            \(whereClause)
            GROUP BY \(groupExpression)
            ORDER BY hourTimestamp ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var bindIndex: Int32 = 1
        bindIndex = Self.bindFrameFilterCTEValues(
            filterComponents,
            to: statement,
            startingAt: bindIndex
        )
        bindIndex = Self.bindFrameFilterWhereValues(
            filterComponents,
            to: statement,
            config: config,
            startingAt: bindIndex
        )
        config.bindDate(startOfDay, to: statement, at: bindIndex)
        bindIndex += 1
        config.bindDate(endOfDay, to: statement, at: bindIndex)

        var timestamps: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let timestamp = config.parseDate(from: statement, column: 0) else { continue }
            timestamps.append(timestamp)
        }

        return timestamps
    }
}

// MARK: - Errors

public enum DataAdapterError: Error, LocalizedError {
    case notInitialized
    case sourceNotAvailable(FrameSource)
    case noSourceForTimestamp(Date)
    case frameNotFound
    case parseFailed
    case databaseError(String)

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
        case .databaseError(let message):
            return message
        }
    }
}
