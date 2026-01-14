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
