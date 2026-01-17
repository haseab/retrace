import Foundation
import Shared
import Database
import Storage
import Search

/// Data source for fetching data from native Retrace storage
/// Wraps DatabaseManager and StorageManager to conform to DataSourceProtocol
public actor RetraceDataSource: DataSourceProtocol {

    // MARK: - DataSourceProtocol Properties

    public let source: FrameSource = .native

    public var isConnected: Bool {
        _isConnected
    }

    /// Native Retrace data has no cutoff - it's the current/primary source
    public var cutoffDate: Date? {
        nil
    }

    // MARK: - Private Properties

    private let database: DatabaseManager
    private let storage: StorageManager
    private var _isConnected = false
    private var searchManager: SearchManager?

    // Cache for videoID -> filename mapping (avoids repeated database lookups)
    private var videoIDToFilenameCache: [Int64: Int64] = [:]

    // MARK: - Initialization

    public init(database: DatabaseManager, storage: StorageManager, searchManager: SearchManager? = nil) {
        self.database = database
        self.storage = storage
        self.searchManager = searchManager
    }

    /// Set the search manager (called after initialization)
    public func setSearchManager(_ searchManager: SearchManager) {
        self.searchManager = searchManager
    }

    // MARK: - DataSourceProtocol Methods

    public func connect() async throws {
        // Database and storage are already initialized by ServiceContainer
        // Just mark as connected
        _isConnected = true
        Log.info("RetraceDataSource connected", category: .app)
    }

    public func disconnect() async {
        _isConnected = false
        Log.info("RetraceDataSource disconnected", category: .app)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFrames(from: startDate, to: endDate, limit: limit)
        } catch {
            // If the table doesn't exist yet (no frames captured), return empty array
            // This allows the DataAdapter to fall through to secondary sources
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        // Optimized: JOIN with video table in single query (Rewind-inspired)
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getMostRecentFrames(limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        // Optimized: JOIN with video table in single query (Rewind-inspired)
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getMostRecentFramesWithVideoInfo(limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFramesBefore(timestamp: timestamp, limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        // Optimized: JOIN with video table in single query (Rewind-inspired)
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFramesAfter(timestamp: timestamp, limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        // Optimized: JOIN with video table in single query (Rewind-inspired)
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        // Look up the frame to get its index
        let frames = try await database.getFrames(from: timestamp, to: timestamp, limit: 1)
        guard let frame = frames.first else {
            throw DataSourceError.frameNotFound
        }

        // Look up the actual video file path from database
        // The segmentID is a database ID (e.g., 7), but the actual file is named with the timestamp
        guard let videoSegment = try await database.getVideoSegment(id: segmentID) else {
            throw DataSourceError.videoNotFound(id: segmentID.value)
        }

        // Extract filename from path (e.g., "chunks/202601/1768624509768" -> "1768624509768")
        let filename = (videoSegment.relativePath as NSString).lastPathComponent
        guard let filenameID = Int64(filename) else {
            throw DataSourceError.invalidVideoPath(path: videoSegment.relativePath)
        }

        // Use the filename as the segment ID for storage lookup
        let fileSegmentID = VideoSegmentID(value: filenameID)
        return try await storage.readFrame(segmentID: fileSegmentID, frameIndex: frame.frameIndexInSegment)
    }

    /// Get frame image by exact videoID and frameIndex (more reliable than timestamp matching)
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        // Look up the actual video file path from database
        // The videoID is a database ID (e.g., 8), but the actual file is named with the timestamp
        // (e.g., "1768624554519") from the path "chunks/202601/1768624554519"
        guard let videoSegment = try await database.getVideoSegment(id: videoID) else {
            throw DataSourceError.videoNotFound(id: videoID.value)
        }

        // Extract filename from path (e.g., "chunks/202601/1768624554519" -> "1768624554519")
        let filename = (videoSegment.relativePath as NSString).lastPathComponent
        guard let filenameID = Int64(filename) else {
            throw DataSourceError.invalidVideoPath(path: videoSegment.relativePath)
        }

        // Use the filename as the segment ID for storage lookup
        let fileSegmentID = VideoSegmentID(value: filenameID)
        return try await storage.readFrame(segmentID: fileSegmentID, frameIndex: frameIndex)
    }

    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
        // Retrace now stores frames as video segments (MP4 without extension)
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        // Get the specific frame to get its videoFrameIndex (already stored in DB)
        let frames = try await database.getFrames(from: timestamp, to: timestamp, limit: 1)
        guard let frame = frames.first else {
            return nil
        }

        // Ensure frame has a valid video ID
        guard frame.videoID.value > 0 else {
            return nil
        }

        // Get video segment to get the file path and frame rate
        guard let videoSegment = try await database.getVideoSegment(id: frame.videoID) else {
            return nil
        }

        // Convert relative path to full path
        let storageDir = await storage.getStorageDirectory()
        let fullPath = storageDir.appendingPathComponent(videoSegment.relativePath).path

        // Get frame rate from database query
        // We need to query the video table directly to get the frameRate column
        // VideoSegment model doesn't store it, so we'll use a fixed 30 FPS for now
        // TODO: Add frameRate to VideoSegment model or query it separately
        let frameRate = 30.0  // Standard frame rate for test videos

        return FrameVideoInfo(
            videoPath: fullPath,
            frameIndex: frame.frameIndexInSegment,
            frameRate: frameRate
        )
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        do {
            return try await database.getSegments(from: startDate, to: endDate)
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: segment table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    // MARK: - Deletion

    public func deleteFrame(frameID: FrameID) async throws {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        try await database.deleteFrame(id: frameID)
        Log.info("[RetraceDataSource] Deleted frame \(frameID.stringValue)", category: .app)
    }

    public func deleteFrames(frameIDs: [FrameID]) async throws {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        for frameID in frameIDs {
            try await database.deleteFrame(id: frameID)
        }
        Log.info("[RetraceDataSource] Deleted \(frameIDs.count) frames", category: .app)
    }

    // MARK: - OCR Nodes

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date) async throws -> [OCRNodeWithText] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        // Find the frame by timestamp
        let frames = try await database.getFrames(from: timestamp, to: timestamp, limit: 1)
        guard let frame = frames.first else {
            return [] // Frame not found
        }

        // Get OCR nodes with text from DatabaseManager
        return try await database.getOCRNodesWithText(frameID: frame.id)
    }

    /// Get all OCR nodes for a frame by frameID (more reliable than timestamp)
    public func getAllOCRNodes(frameID: FrameID) async throws -> [OCRNodeWithText] {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        // Get OCR nodes with text from DatabaseManager
        return try await database.getOCRNodesWithText(frameID: frameID)
    }

    // MARK: - Search

    /// Search frames using FTS index
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard _isConnected else {
            throw DataSourceError.notConnected
        }

        guard let searchManager = searchManager else {
            throw DataSourceError.unsupportedOperation
        }

        // Use the SearchManager to perform FTS search
        var results = try await searchManager.search(query: query)

        // Tag all results with native source
        results.results = results.results.map { result in
            var modifiedResult = result
            modifiedResult.source = .native
            return modifiedResult
        }

        return results
    }
}
