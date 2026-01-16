import Foundation
import Shared

/// Unified data adapter that routes queries to appropriate data sources
/// Seamlessly blends data from multiple sources (Rewind, Retrace, etc.)
/// based on timestamps and source availability
public actor DataAdapter {

    // MARK: - Properties

    /// Primary data source (native Retrace)
    private let primarySource: any DataSourceProtocol

    /// Secondary sources (Rewind, etc.) keyed by FrameSource
    private var secondarySources: [FrameSource: any DataSourceProtocol] = [:]

    /// Whether the adapter is initialized and ready
    private var isInitialized = false

    // MARK: - Session Cache

    /// Cache key for session queries (date range hash)
    private struct SessionCacheKey: Hashable {
        let startDate: Date
        let endDate: Date
    }

    /// Cached session results with expiry
    private struct SessionCacheEntry {
        let sessions: [AppSession]
        let timestamp: Date
    }

    /// Session query cache - keyed by date range
    private var sessionCache: [SessionCacheKey: SessionCacheEntry] = [:]

    /// How long cached sessions remain valid (5 minutes)
    private let sessionCacheTTL: TimeInterval = 300

    // MARK: - Initialization

    public init(primarySource: any DataSourceProtocol) {
        self.primarySource = primarySource
    }

    /// Register a secondary data source (e.g., Rewind)
    public func registerSource(_ source: any DataSourceProtocol) async {
        secondarySources[await source.source] = source
        Log.info("Registered data source: \(await source.source.displayName)", category: .app)
    }

    /// Initialize all data sources
    public func initialize() async throws {
        // Connect primary source
        try await primarySource.connect()

        // Connect all secondary sources
        for (sourceType, source) in secondarySources {
            do {
                try await source.connect()
                Log.info("✓ Connected to \(sourceType.displayName) data source", category: .app)
            } catch {
                Log.warning("Failed to connect to \(sourceType.displayName): \(error)", category: .app)
                // Remove failed source
                secondarySources.removeValue(forKey: sourceType)
            }
        }

        isInitialized = true
        Log.info("DataAdapter initialized with \(secondarySources.count + 1) source(s)", category: .app)
    }

    /// Shutdown all data sources
    public func shutdown() async {
        await primarySource.disconnect()

        for (_, source) in secondarySources {
            await source.disconnect()
        }

        secondarySources.removeAll()
        isInitialized = false
        Log.info("DataAdapter shutdown complete", category: .app)
    }

    // MARK: - Frame Retrieval

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    /// This is the preferred method for timeline views to avoid N+1 queries
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFramesWithVideoInfo called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        Log.info("[DataAdapter] getFramesWithVideoInfo: \(dateFormatter.string(from: startDate)) → \(dateFormatter.string(from: endDate)), limit=\(limit)", category: .app)

        var allFrames: [FrameWithVideoInfo] = []

        // Check secondary sources
        for (sourceType, source) in secondarySources {
            let isConnected = await source.isConnected
            guard isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                if startDate < cutoff {
                    let effectiveEnd = min(endDate, cutoff)
                    let frames = try await source.getFramesWithVideoInfo(from: startDate, to: effectiveEnd, limit: limit)
                    allFrames.append(contentsOf: frames)
                    Log.info("[DataAdapter] ✓ Got \(frames.count) frames with video info from \(sourceType.displayName)", category: .app)
                }
            } else {
                let frames = try await source.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames with video info from \(sourceType.displayName)", category: .app)
            }
        }

        // Get frames from primary source
        var primaryStartDate = startDate
        for (_, source) in secondarySources {
            if let cutoff = await source.cutoffDate, await source.isConnected {
                primaryStartDate = max(primaryStartDate, cutoff)
            }
        }

        if primaryStartDate < endDate {
            let primaryFrames = try await primarySource.getFramesWithVideoInfo(from: primaryStartDate, to: endDate, limit: limit)
            allFrames.append(contentsOf: primaryFrames)
            Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames with video info from primary source", category: .app)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }

        let result = Array(allFrames.prefix(limit))
        Log.info("[DataAdapter] Returning \(result.count) frames with video info", category: .app)
        return result
    }

    /// Get frames in a time range, blending data from all available sources
    /// Automatically routes to appropriate source based on timestamps and cutoff dates
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500) async throws -> [FrameReference] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFrames called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        Log.info("[DataAdapter] getFrames: \(dateFormatter.string(from: startDate)) → \(dateFormatter.string(from: endDate)), limit=\(limit)", category: .app)
        Log.info("[DataAdapter] Secondary sources registered: \(secondarySources.count) [\(secondarySources.keys.map { $0.displayName }.joined(separator: ", "))]", category: .app)

        var allFrames: [FrameReference] = []

        // Check if any secondary source can provide data for this range
        for (sourceType, source) in secondarySources {
            let isConnected = await source.isConnected
            Log.info("[DataAdapter] Checking \(sourceType.displayName): connected=\(isConnected)", category: .app)
            guard isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                Log.info("[DataAdapter] \(sourceType.displayName) cutoff: \(dateFormatter.string(from: cutoff))", category: .app)
                // Source only has data before cutoff
                if startDate < cutoff {
                    let effectiveEnd = min(endDate, cutoff)
                    Log.info("[DataAdapter] Querying \(sourceType.displayName): \(dateFormatter.string(from: startDate)) → \(dateFormatter.string(from: effectiveEnd))", category: .app)
                    let frames = try await source.getFrames(from: startDate, to: effectiveEnd, limit: limit)
                    allFrames.append(contentsOf: frames)
                    Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
                } else {
                    Log.info("[DataAdapter] Skipping \(sourceType.displayName): startDate >= cutoff", category: .app)
                }
            } else {
                // Source has no cutoff - can provide data for any range
                Log.info("[DataAdapter] \(sourceType.displayName) has no cutoff, querying full range", category: .app)
                let frames = try await source.getFrames(from: startDate, to: endDate, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
            }
        }

        // Get frames from primary source (native Retrace)
        // If secondary sources have cutoffs, only query primary for dates after the latest cutoff
        var primaryStartDate = startDate
        for (_, source) in secondarySources {
            if let cutoff = await source.cutoffDate, await source.isConnected {
                primaryStartDate = max(primaryStartDate, cutoff)
            }
        }

        Log.info("[DataAdapter] Primary source query: \(dateFormatter.string(from: primaryStartDate)) → \(dateFormatter.string(from: endDate))", category: .app)

        if primaryStartDate < endDate {
            let primaryFrames = try await primarySource.getFrames(from: primaryStartDate, to: endDate, limit: limit)
            allFrames.append(contentsOf: primaryFrames)
            Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames from primary source", category: .app)
        } else {
            Log.info("[DataAdapter] Skipping primary source: primaryStartDate >= endDate", category: .app)
        }

        // Sort all frames by timestamp (ascending - oldest first, chronological order)
        allFrames.sort { $0.timestamp < $1.timestamp }

        Log.info("[DataAdapter] Total frames after merge & sort: \(allFrames.count)", category: .app)

        // Return up to limit
        let result = Array(allFrames.prefix(limit))
        Log.info("[DataAdapter] Returning \(result.count) frames", category: .app)
        return result
    }

    /// Get the most recent frames with video info (optimized - single query with JOINs)
    /// This is the preferred method for timeline views to avoid N+1 queries
    public func getMostRecentFramesWithVideoInfo(limit: Int = 250) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            Log.error("[DataAdapter] getMostRecentFramesWithVideoInfo called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        Log.info("[DataAdapter] getMostRecentFramesWithVideoInfo: fetching \(limit) most recent frames", category: .app)

        var allFrames: [FrameWithVideoInfo] = []

        // Get most recent frames from primary source
        let primaryFrames = try await primarySource.getMostRecentFramesWithVideoInfo(limit: limit)
        allFrames.append(contentsOf: primaryFrames)
        Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames with video info from primary source", category: .app)

        // Get most recent frames from secondary sources
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }
            let sourceFrames = try await source.getMostRecentFramesWithVideoInfo(limit: limit)
            allFrames.append(contentsOf: sourceFrames)
            Log.info("[DataAdapter] ✓ Got \(sourceFrames.count) frames with video info from \(sourceType.displayName)", category: .app)
        }

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        let result = Array(allFrames.prefix(limit))

        Log.info("[DataAdapter] Returning \(result.count) most recent frames with video info", category: .app)
        return result
    }

    /// Get the most recent frames across all sources
    /// Returns frames sorted by timestamp descending (newest first)
    public func getMostRecentFrames(limit: Int = 250) async throws -> [FrameReference] {
        guard isInitialized else {
            Log.error("[DataAdapter] getMostRecentFrames called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        Log.info("[DataAdapter] getMostRecentFrames: fetching \(limit) most recent frames", category: .app)

        var allFrames: [FrameReference] = []

        // Get most recent frames from primary source
        Log.info("[DataAdapter] Querying primary source...", category: .app)
        let primaryFrames = try await primarySource.getMostRecentFrames(limit: limit)
        allFrames.append(contentsOf: primaryFrames)
        Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames from primary source", category: .app)

        // Get most recent frames from secondary sources
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }

            Log.info("[DataAdapter] Querying \(sourceType.displayName)...", category: .app)
            let sourceFrames = try await source.getMostRecentFrames(limit: limit)
            allFrames.append(contentsOf: sourceFrames)
            Log.info("[DataAdapter] ✓ Got \(sourceFrames.count) frames from \(sourceType.displayName)", category: .app)
        }

        // Sort all frames by timestamp descending (newest first) and take top N
        allFrames.sort { $0.timestamp > $1.timestamp }
        let result = Array(allFrames.prefix(limit))

        Log.info("[DataAdapter] Returning \(result.count) most recent frames", category: .app)
        return result
    }

    /// Get frames with video info before a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFramesWithVideoInfoBefore called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Check secondary sources
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                let effectiveTimestamp = min(timestamp, cutoff)
                let frames = try await source.getFramesWithVideoInfoBefore(timestamp: effectiveTimestamp, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames with video info from \(sourceType.displayName)", category: .app)
            } else {
                let frames = try await source.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
                allFrames.append(contentsOf: frames)
            }
        }

        // Get frames from primary source
        let primaryFrames = try await primarySource.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
        allFrames.append(contentsOf: primaryFrames)

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get frames with video info after a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFramesWithVideoInfoAfter called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        var allFrames: [FrameWithVideoInfo] = []

        // Check secondary sources (respecting cutoffs)
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                if timestamp < cutoff {
                    let frames = try await source.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
                    allFrames.append(contentsOf: frames)
                    Log.info("[DataAdapter] ✓ Got \(frames.count) frames with video info from \(sourceType.displayName)", category: .app)
                }
            } else {
                let frames = try await source.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
                allFrames.append(contentsOf: frames)
            }
        }

        // Get frames from primary source
        let primaryFrames = try await primarySource.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
        allFrames.append(contentsOf: primaryFrames)

        // Sort by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames sorted by timestamp descending (newest first of the older batch)
    public func getFramesBefore(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFramesBefore called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        Log.info("[DataAdapter] getFramesBefore: \(dateFormatter.string(from: timestamp)), limit=\(limit)", category: .app)

        var allFrames: [FrameReference] = []

        // Check secondary sources for data before timestamp
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }

            // For sources with cutoffs, only query if timestamp is within their range
            if let cutoff = await source.cutoffDate {
                let effectiveTimestamp = min(timestamp, cutoff)
                Log.info("[DataAdapter] Querying \(sourceType.displayName) for frames before \(dateFormatter.string(from: effectiveTimestamp))", category: .app)
                let frames = try await source.getFramesBefore(timestamp: effectiveTimestamp, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
            } else {
                let frames = try await source.getFramesBefore(timestamp: timestamp, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
            }
        }

        // Get frames from primary source
        Log.info("[DataAdapter] Querying primary source for frames before \(dateFormatter.string(from: timestamp))", category: .app)
        let primaryFrames = try await primarySource.getFramesBefore(timestamp: timestamp, limit: limit)
        allFrames.append(contentsOf: primaryFrames)
        Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames from primary source", category: .app)

        // Sort all frames by timestamp descending (newest first) and take top N
        allFrames.sort { $0.timestamp > $1.timestamp }
        let result = Array(allFrames.prefix(limit))

        Log.info("[DataAdapter] Returning \(result.count) frames before timestamp", category: .app)
        return result
    }

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames sorted by timestamp ascending (oldest first of the newer batch)
    public func getFramesAfter(timestamp: Date, limit: Int = 300) async throws -> [FrameReference] {
        guard isInitialized else {
            Log.error("[DataAdapter] getFramesAfter called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        Log.info("[DataAdapter] getFramesAfter: \(dateFormatter.string(from: timestamp)), limit=\(limit)", category: .app)

        var allFrames: [FrameReference] = []

        // Check secondary sources for data after timestamp (respecting cutoffs)
        for (sourceType, source) in secondarySources {
            guard await source.isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                // Only query if timestamp is before cutoff
                if timestamp < cutoff {
                    Log.info("[DataAdapter] Querying \(sourceType.displayName) for frames after \(dateFormatter.string(from: timestamp))", category: .app)
                    let frames = try await source.getFramesAfter(timestamp: timestamp, limit: limit)
                    allFrames.append(contentsOf: frames)
                    Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
                }
            } else {
                let frames = try await source.getFramesAfter(timestamp: timestamp, limit: limit)
                allFrames.append(contentsOf: frames)
                Log.info("[DataAdapter] ✓ Got \(frames.count) frames from \(sourceType.displayName)", category: .app)
            }
        }

        // Get frames from primary source
        Log.info("[DataAdapter] Querying primary source for frames after \(dateFormatter.string(from: timestamp))", category: .app)
        let primaryFrames = try await primarySource.getFramesAfter(timestamp: timestamp, limit: limit)
        allFrames.append(contentsOf: primaryFrames)
        Log.info("[DataAdapter] ✓ Got \(primaryFrames.count) frames from primary source", category: .app)

        // Sort all frames by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.timestamp < $1.timestamp }
        let result = Array(allFrames.prefix(limit))

        Log.info("[DataAdapter] Returning \(result.count) frames after timestamp", category: .app)
        return result
    }

    /// Get the timestamp of the most recent frame across all sources
    /// Used to find where data actually exists when recent queries return empty
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        guard isInitialized else {
            Log.error("[DataAdapter] getMostRecentFrameTimestamp called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        Log.info("[DataAdapter] getMostRecentFrameTimestamp: searching for latest frame", category: .app)

        // Just get 1 frame from each source and compare
        let frames = try await getMostRecentFrames(limit: 1)

        if let mostRecent = frames.first {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            Log.info("[DataAdapter] Most recent frame: \(dateFormatter.string(from: mostRecent.timestamp))", category: .app)
            return mostRecent.timestamp
        }

        Log.info("[DataAdapter] No frames found in any source", category: .app)
        return nil
    }

    /// Get image data for a specific frame
    /// Routes to appropriate source based on frame's source property
    public func getFrameImage(segmentID: SegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Route to appropriate data source based on frame source
        if frameSource == .native {
            return try await primarySource.getFrameImage(segmentID: segmentID, timestamp: timestamp)
        }

        // Check secondary sources
        if let source = secondarySources[frameSource], await source.isConnected {
            return try await source.getFrameImage(segmentID: segmentID, timestamp: timestamp)
        }

        // Fallback: try primary source
        Log.warning("No source found for \(frameSource.displayName), falling back to primary", category: .app)
        return try await primarySource.getFrameImage(segmentID: segmentID, timestamp: timestamp)
    }

    /// Convenience method that determines source from timestamp
    /// Uses cutoff dates to route appropriately
    public func getFrameImage(segmentID: SegmentID, timestamp: Date) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Check if any secondary source should handle this timestamp
        for (_, source) in secondarySources {
            guard await source.isConnected else { continue }

            if let cutoff = await source.cutoffDate, timestamp < cutoff {
                return try await source.getFrameImage(segmentID: segmentID, timestamp: timestamp)
            }
        }

        // Default to primary source
        return try await primarySource.getFrameImage(segmentID: segmentID, timestamp: timestamp)
    }

    /// Get video info for a frame (if source is video-based)
    public func getFrameVideoInfo(segmentID: SegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> FrameVideoInfo? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Route to appropriate data source
        if frameSource == .native {
            return try await primarySource.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp)
        }

        // Check secondary sources
        if let source = secondarySources[frameSource], await source.isConnected {
            return try await source.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp)
        }

        // Fallback
        return nil
    }

    // MARK: - Session Retrieval

    /// Get sessions in a time range, blending data from all available sources
    /// Results are cached for 5 minutes to avoid repeated queries
    public func getSessions(from startDate: Date, to endDate: Date) async throws -> [AppSession] {
        guard isInitialized else {
            Log.error("[DataAdapter] getSessions called but not initialized", category: .app)
            throw DataAdapterError.notInitialized
        }

        let cacheKey = SessionCacheKey(startDate: startDate, endDate: endDate)

        // Check cache first
        if let cached = sessionCache[cacheKey] {
            let age = Date().timeIntervalSince(cached.timestamp)
            if age < sessionCacheTTL {
                Log.info("[DataAdapter] getSessions: cache hit (\(cached.sessions.count) sessions, age: \(Int(age))s)", category: .app)
                return cached.sessions
            } else {
                // Expired - remove from cache
                sessionCache.removeValue(forKey: cacheKey)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        Log.info("[DataAdapter] getSessions: cache miss, querying \(dateFormatter.string(from: startDate)) → \(dateFormatter.string(from: endDate))", category: .app)

        var allSessions: [AppSession] = []

        // Check if any secondary source can provide data for this range
        for (sourceType, source) in secondarySources {
            let isConnected = await source.isConnected
            guard isConnected else { continue }

            if let cutoff = await source.cutoffDate {
                // Source only has data before cutoff
                if startDate < cutoff {
                    let effectiveEnd = min(endDate, cutoff)
                    Log.info("[DataAdapter] Querying \(sourceType.displayName) for sessions: \(dateFormatter.string(from: startDate)) → \(dateFormatter.string(from: effectiveEnd))", category: .app)
                    let sessions = try await source.getSessions(from: startDate, to: effectiveEnd)
                    allSessions.append(contentsOf: sessions)
                    Log.info("[DataAdapter] ✓ Got \(sessions.count) sessions from \(sourceType.displayName)", category: .app)
                }
            } else {
                // Source has no cutoff - can provide data for any range
                let sessions = try await source.getSessions(from: startDate, to: endDate)
                allSessions.append(contentsOf: sessions)
                Log.info("[DataAdapter] ✓ Got \(sessions.count) sessions from \(sourceType.displayName)", category: .app)
            }
        }

        // Get sessions from primary source (native Retrace)
        // If secondary sources have cutoffs, only query primary for dates after the latest cutoff
        var primaryStartDate = startDate
        for (_, source) in secondarySources {
            if let cutoff = await source.cutoffDate, await source.isConnected {
                primaryStartDate = max(primaryStartDate, cutoff)
            }
        }

        if primaryStartDate < endDate {
            let primarySessions = try await primarySource.getSessions(from: primaryStartDate, to: endDate)
            allSessions.append(contentsOf: primarySessions)
            Log.info("[DataAdapter] ✓ Got \(primarySessions.count) sessions from primary source", category: .app)
        }

        // Sort all sessions by start time (ascending - oldest first)
        allSessions.sort { $0.startTime < $1.startTime }

        // Cache the results
        sessionCache[cacheKey] = SessionCacheEntry(sessions: allSessions, timestamp: Date())

        Log.info("[DataAdapter] Total sessions after merge & sort: \(allSessions.count) (cached)", category: .app)
        return allSessions
    }

    /// Invalidate the session cache (call when new data is recorded)
    public func invalidateSessionCache() {
        sessionCache.removeAll()
        Log.info("[DataAdapter] Session cache invalidated", category: .app)
    }

    // MARK: - Source Information

    /// Get all registered sources
    public var registeredSources: [FrameSource] {
        get async {
            var sources: [FrameSource] = [await primarySource.source]
            sources.append(contentsOf: secondarySources.keys)
            return sources
        }
    }

    /// Check if a specific source is available
    public func isSourceAvailable(_ source: FrameSource) async -> Bool {
        if await primarySource.source == source {
            return await primarySource.isConnected
        }
        guard let secondarySource = secondarySources[source] else {
            return false
        }
        return await secondarySource.isConnected
    }

    // MARK: - Deletion

    /// Delete a frame from the appropriate data source
    /// Routes to the correct source based on the frame's source property
    public func deleteFrame(frameID: FrameID, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        if frameSource == .native {
            try await primarySource.deleteFrame(frameID: frameID)
            Log.info("[DataAdapter] Deleted frame from primary source", category: .app)
            return
        }

        // Check secondary sources
        if let source = secondarySources[frameSource], await source.isConnected {
            try await source.deleteFrame(frameID: frameID)
            Log.info("[DataAdapter] Deleted frame from \(frameSource.displayName)", category: .app)
            return
        }

        throw DataAdapterError.sourceNotAvailable(frameSource)
    }

    /// Delete multiple frames from their respective data sources
    /// Groups frames by source and deletes in batches
    public func deleteFrames(_ frames: [(frameID: FrameID, source: FrameSource)]) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Group frames by source
        var framesBySource: [FrameSource: [FrameID]] = [:]
        for (frameID, source) in frames {
            framesBySource[source, default: []].append(frameID)
        }

        // Delete from each source
        for (frameSource, frameIDs) in framesBySource {
            if frameSource == .native {
                try await primarySource.deleteFrames(frameIDs: frameIDs)
                Log.info("[DataAdapter] Deleted \(frameIDs.count) frames from primary source", category: .app)
            } else if let source = secondarySources[frameSource], await source.isConnected {
                try await source.deleteFrames(frameIDs: frameIDs)
                Log.info("[DataAdapter] Deleted \(frameIDs.count) frames from \(frameSource.displayName)", category: .app)
            } else {
                Log.warning("[DataAdapter] Source \(frameSource.displayName) not available for deletion", category: .app)
            }
        }
    }

    /// Delete a frame by timestamp (more reliable for Rewind data where UUIDs are synthetic)
    public func deleteFrameByTimestamp(_ timestamp: Date, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // For Rewind source, use the timestamp-based deletion method
        if frameSource == .rewind {
            if let rewindSource = secondarySources[.rewind] as? RewindDataSource {
                try await rewindSource.deleteFrameByTimestamp(timestamp)
                Log.info("[DataAdapter] Deleted Rewind frame by timestamp", category: .app)
                return
            }
            throw DataAdapterError.sourceNotAvailable(frameSource)
        }

        // For native source, we need to find the frame by timestamp first
        // This is a fallback - prefer using deleteFrame with frameID for native data
        Log.warning("[DataAdapter] deleteFrameByTimestamp called for native source - this is inefficient", category: .app)
        throw DataSourceError.unsupportedOperation
    }

    // MARK: - URL Bounding Box Detection

    /// Get the bounding box of a browser URL on screen for a given frame
    /// Returns the bounding box if the URL text is found in the OCR nodes
    /// Currently only supported for Rewind data source
    public func getURLBoundingBox(timestamp: Date, source frameSource: FrameSource) async throws -> RewindDataSource.URLBoundingBox? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Only Rewind source has OCR node data with bounding boxes
        if frameSource == .rewind {
            if let rewindSource = secondarySources[.rewind] as? RewindDataSource {
                return try await rewindSource.getURLBoundingBox(timestamp: timestamp)
            }
        }

        // Native source doesn't have this capability yet
        return nil
    }

    // MARK: - OCR Node Detection (for text selection)

    /// Get all OCR nodes for a given frame
    /// Returns array of nodes with bounding boxes and text content
    /// Currently only supported for Rewind data source
    public func getAllOCRNodes(timestamp: Date, source frameSource: FrameSource) async throws -> [RewindDataSource.OCRNode] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Only Rewind source has OCR node data
        if frameSource == .rewind {
            if let rewindSource = secondarySources[.rewind] as? RewindDataSource {
                return try await rewindSource.getAllOCRNodes(timestamp: timestamp)
            }
        }

        // Native source doesn't have this capability yet
        return []
    }

    // MARK: - App Discovery

    /// Get all distinct apps from all data sources
    /// Returns apps sorted by usage frequency (most used first)
    public func getDistinctApps() async throws -> [RewindDataSource.AppInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Try Rewind data source first (it has the most historical data)
        if let rewindSource = secondarySources[.rewind] as? RewindDataSource,
           await rewindSource.isConnected {
            return try await rewindSource.getDistinctApps()
        }

        // Fallback to empty if no source available
        Log.warning("[DataAdapter] No data source available for app discovery", category: .app)
        return []
    }

    // MARK: - Full-Text Search

    /// Search across all data sources
    /// Prioritizes Rewind data source if available (since it has the most OCR data)
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        Log.info("[DataAdapter] Search request: '\(query.text)'", category: .app)

        // Try Rewind data source first (if available and connected)
        if let rewindSource = secondarySources[.rewind] as? RewindDataSource,
           await rewindSource.isConnected {
            Log.debug("[DataAdapter] Routing search to RewindDataSource", category: .app)
            return try await rewindSource.search(query: query)
        }

        // Fallback to error if no searchable source available
        Log.warning("[DataAdapter] No searchable data source available", category: .app)
        throw DataAdapterError.sourceNotAvailable(.rewind)
    }
}

// MARK: - Errors

public enum DataAdapterError: Error, LocalizedError {
    case notInitialized
    case sourceNotAvailable(FrameSource)
    case noSourceForTimestamp(Date)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "DataAdapter not initialized"
        case .sourceNotAvailable(let source):
            return "Data source not available: \(source.displayName)"
        case .noSourceForTimestamp(let date):
            return "No data source available for timestamp: \(date)"
        }
    }
}
