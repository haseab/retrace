import Foundation
import Shared
import Database
import Storage
import AppKit

/// Data source for fetching data from native Retrace storage
/// Delegates all query logic to UnifiedDatabaseAdapter
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

    /// In-memory cache for extracted frame images
    private let imageCache = NSCache<NSString, NSData>()

    // Unified adapter for all database queries
    private var adapter: UnifiedDatabaseAdapter?

    // MARK: - Initialization

    public init(database: DatabaseManager, storage: StorageManager) {
        self.database = database
        self.storage = storage

        // Configure image cache (limit to ~200 frames = ~100MB)
        imageCache.countLimit = 200
        imageCache.totalCostLimit = 100 * 1024 * 1024
    }

    // MARK: - DataSourceProtocol Methods

    public func connect() async throws {
        // Database and storage are already initialized by ServiceContainer
        // Create the unified adapter with SQLite connection and Retrace config
        let connection = SQLiteConnection(db: await database.getConnection())
        let config = DatabaseConfig.retrace
        self.adapter = UnifiedDatabaseAdapter(connection: connection, config: config)

        _isConnected = true
        Log.info("RetraceDataSource connected", category: .app)
    }

    public func disconnect() async {
        adapter = nil
        _isConnected = false
        Log.info("RetraceDataSource disconnected", category: .app)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            let framesWithVideo = try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
            return framesWithVideo.map { $0.frame }
        } catch {
            // If the table doesn't exist yet (no frames captured), return empty array
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: frames table doesn't exist yet, returning empty array", category: .app)
                return []
            }
            throw error
        }
    }

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            return try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            let framesWithVideo = try await adapter.getMostRecentFramesWithVideoInfo(limit: limit)
            return framesWithVideo.map { $0.frame }
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            return try await adapter.getMostRecentFramesWithVideoInfo(limit: limit)
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            let framesWithVideo = try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
            return framesWithVideo.map { $0.frame }
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            return try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            let framesWithVideo = try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
            return framesWithVideo.map { $0.frame }
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            return try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
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
        let cacheKey = "\(segmentID.stringValue)_\(timestamp.timeIntervalSince1970)" as NSString

        if let cachedData = imageCache.object(forKey: cacheKey) {
            return cachedData as Data
        }

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
        let imageData = try await storage.readFrame(segmentID: fileSegmentID, frameIndex: frame.frameIndexInSegment)

        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        return imageData
    }

    /// Get frame image by exact videoID and frameIndex (more reliable than timestamp matching)
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        let cacheKey = "\(videoID.stringValue)_\(frameIndex)" as NSString

        if let cachedData = imageCache.object(forKey: cacheKey) {
            return cachedData as Data
        }

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
        let imageData = try await storage.readFrame(segmentID: fileSegmentID, frameIndex: frameIndex)

        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        return imageData
    }

    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        return try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp)
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            return try await adapter.getSegments(from: startDate, to: endDate)
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
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        try await adapter.deleteFrame(frameID: frameID)
        Log.info("[RetraceDataSource] Deleted frame \(frameID.stringValue)", category: .app)
    }

    public func deleteFrames(frameIDs: [FrameID]) async throws {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        try await adapter.deleteFrames(frameIDs: frameIDs)
        Log.info("[RetraceDataSource] Deleted \(frameIDs.count) frames", category: .app)
    }

    // MARK: - OCR Nodes

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date) async throws -> [OCRNodeWithText] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        return try await adapter.getAllOCRNodes(timestamp: timestamp)
    }

    /// Get all OCR nodes for a frame by frameID (more reliable than timestamp)
    public func getAllOCRNodes(frameID: FrameID) async throws -> [OCRNodeWithText] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        return try await adapter.getAllOCRNodes(frameID: frameID)
    }

    // MARK: - Search

    /// Search frames using FTS index (delegated to adapter)
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        do {
            var results = try await adapter.search(query: query)

            // Tag all results with native source
            results.results = results.results.map { result in
                var modifiedResult = result
                modifiedResult.source = .native
                return modifiedResult
            }

            return results
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("no such table") {
                Log.info("RetraceDataSource: FTS table doesn't exist yet, returning empty results", category: .app)
                return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
            }
            throw error
        }
    }

    // MARK: - URL Bounding Box Detection

    /// Get bounding box for URL in a frame's OCR text
    public func getURLBoundingBox(timestamp: Date) async throws -> URLBoundingBox? {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        return try await adapter.getURLBoundingBox(timestamp: timestamp)
    }

    // MARK: - App Discovery

    /// Get distinct apps from the segment table
    public func getDistinctApps() async throws -> [AppInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        let bundleIDs = try await adapter.getDistinctApps(limit: 100)

        // Resolve app names on main actor
        return await MainActor.run {
            bundleIDs.compactMap { bundleID -> AppInfo? in
                let name = Self.resolveAppName(bundleID: bundleID)
                return AppInfo(bundleID: bundleID, name: name)
            }
        }
    }

    @MainActor
    private static func resolveAppName(bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: infoPlistURL) {
                if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                    return displayName
                }
                if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                    return bundleName
                }
            }
            let fileName = appURL.deletingPathExtension().lastPathComponent
            if !fileName.isEmpty { return fileName }
        }

        // Check Chrome Apps folder
        let chromeAppsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Chrome Apps")
        if FileManager.default.fileExists(atPath: chromeAppsPath.path) {
            if let apps = try? FileManager.default.contentsOfDirectory(at: chromeAppsPath, includingPropertiesForKeys: nil) {
                for appURL in apps where appURL.pathExtension == "app" {
                    let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
                    if let plist = NSDictionary(contentsOf: infoPlistURL),
                       let appBundleID = plist["CFBundleIdentifier"] as? String,
                       appBundleID == bundleID {
                        if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                            return displayName
                        }
                        if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                            return bundleName
                        }
                        return appURL.deletingPathExtension().lastPathComponent
                    }
                }
            }
        }

        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}
