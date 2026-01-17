import Foundation
import SQLCipher
import Shared
import Database
import Storage
import AVFoundation
import AppKit

/// Data source for fetching historical data from Rewind's encrypted database
/// Uses SQLCipher to decrypt the database on-demand
/// Delegates all query logic to UnifiedDatabaseAdapter
public actor RewindDataSource: DataSourceProtocol {

    // MARK: - DataSourceProtocol Properties

    public let source: FrameSource = .rewind

    public var isConnected: Bool {
        _isConnected
    }

    public var cutoffDate: Date? {
        _cutoffDate
    }

    // MARK: - Private Properties

    private var db: OpaquePointer?
    private let rewindDBPath: String
    private let rewindChunksPath: String
    private let password: String
    private var _isConnected = false
    private let _cutoffDate: Date

    /// In-memory cache for extracted frame images
    private let imageCache = NSCache<NSString, NSData>()

    /// Unified adapter for all database queries
    private var adapter: UnifiedDatabaseAdapter?

    // MARK: - Initialization

    public init(
        password: String,
        cutoffDate: Date = Date(timeIntervalSince1970: 1766217600) // Dec 20, 2025 00:00:00 UTC
    ) throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.rewindDBPath = "\(homeDir)/Library/Application Support/com.memoryvault.MemoryVault/db-enc.sqlite3"
        self.rewindChunksPath = "\(homeDir)/Library/Application Support/com.memoryvault.MemoryVault/chunks"
        self.password = password
        self._cutoffDate = cutoffDate

        // Configure image cache (limit to ~200 frames = ~100MB)
        imageCache.countLimit = 200
        imageCache.totalCostLimit = 100 * 1024 * 1024

        guard FileManager.default.fileExists(atPath: rewindDBPath) else {
            throw RewindDataSourceError.databaseNotFound(path: rewindDBPath)
        }
    }

    // MARK: - DataSourceProtocol Methods

    public func connect() async throws {
        guard !_isConnected else { return }

        Log.info("[RewindDataSource] Opening encrypted database at: \(rewindDBPath)", category: .app)

        guard sqlite3_open(rewindDBPath, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            Log.error("[RewindDataSource] Failed to open database: \(errorMsg)", category: .app)
            throw RewindDataSourceError.connectionFailed(underlying: errorMsg)
        }

        // Set encryption key
        var keyError: UnsafeMutablePointer<Int8>?
        let keySQL = "PRAGMA key = '\(password)'"
        if sqlite3_exec(db, keySQL, nil, nil, &keyError) != SQLITE_OK {
            let error = keyError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(keyError)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to set encryption key: \(error)")
        }

        // Set cipher compatibility (Rewind uses SQLCipher 4)
        var compatError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError) != SQLITE_OK {
            let error = compatError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(compatError)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to set cipher compatibility: \(error)")
        }

        // Verify connection
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db!))
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to verify encryption key: \(errMsg)")
        }

        guard sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to read from encrypted database")
        }

        let tableCount = sqlite3_column_int(testStmt, 0)
        sqlite3_finalize(testStmt)
        Log.info("[RewindDataSource] ✓ Encryption verified (\(tableCount) objects in schema)", category: .app)

        // Create unified adapter for all queries
        let connection = SQLCipherConnection(db: db)
        let config = DatabaseConfig.rewind
        self.adapter = UnifiedDatabaseAdapter(connection: connection, config: config)

        _isConnected = true
        Log.info("[RewindDataSource] ✓ Connected to Rewind database successfully", category: .app)
    }

    public func disconnect() async {
        adapter = nil
        guard let db = db else { return }
        sqlite3_close(db)
        self.db = nil
        _isConnected = false
        Log.info("Disconnected from Rewind database", category: .app)
    }

    // MARK: - Frame Queries (Delegated to Adapter)

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        let framesWithVideo = try await getMostRecentFramesWithVideoInfo(limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getMostRecentFramesWithVideoInfo(limit: limit)
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
    }

    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp)
    }

    // MARK: - Segment Queries (Delegated to Adapter)

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getSegments(from: startDate, to: endDate)
    }

    // MARK: - OCR Nodes (Delegated to Adapter)

    public typealias OCRNode = OCRNodeWithText

    public func getAllOCRNodes(timestamp: Date) async throws -> [OCRNode] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getAllOCRNodes(timestamp: timestamp)
    }

    public func getAllOCRNodes(frameID: FrameID) async throws -> [OCRNode] {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        return try await adapter.getAllOCRNodes(frameID: frameID)
    }

    // MARK: - Search (Delegated to Adapter)

    public func search(query: SearchQuery) async throws -> SearchResults {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        var results = try await adapter.search(query: query)

        // Tag all results with rewind source
        results.results = results.results.map { result in
            var modifiedResult = result
            modifiedResult.source = .rewind
            return modifiedResult
        }

        return results
    }

    // MARK: - Deletion (Delegated to Adapter)

    public func deleteFrame(frameID: FrameID) async throws {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        try await adapter.deleteFrame(frameID: frameID)
    }

    public func deleteFrames(frameIDs: [FrameID]) async throws {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }
        try await adapter.deleteFrames(frameIDs: frameIDs)
    }

    // MARK: - Image Extraction (Source-Specific)

    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        let cacheKey = "\(segmentID.stringValue)_\(timestamp.timeIntervalSince1970)" as NSString

        if let cachedData = imageCache.object(forKey: cacheKey) {
            return cachedData as Data
        }

        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        // Get video info from adapter
        guard let videoInfo = try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp) else {
            throw DataSourceError.frameNotFound
        }

        guard FileManager.default.fileExists(atPath: videoInfo.videoPath) else {
            throw RewindDataSourceError.videoFileNotFound(path: videoInfo.videoPath)
        }

        let imageData = try extractFrameFromVideo(
            videoPath: videoInfo.videoPath,
            frameIndex: videoInfo.frameIndex,
            frameRate: videoInfo.frameRate
        )

        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        return imageData
    }

    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        let cacheKey = "\(videoID.stringValue)_\(frameIndex)" as NSString

        if let cachedData = imageCache.object(forKey: cacheKey) {
            return cachedData as Data
        }

        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Query video info directly (adapter doesn't have this specific query)
        let sql = """
            SELECT v.path, v.frameRate
            FROM video v
            WHERE v.id = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, videoID.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataSourceError.frameNotFound
        }

        guard let pathPtr = sqlite3_column_text(statement, 0) else {
            throw RewindDataSourceError.videoFileNotFound(path: "No video path for videoID \(videoID.stringValue)")
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(statement, 1)

        let fullVideoPath = "\(rewindChunksPath)/\(videoPath)"

        guard FileManager.default.fileExists(atPath: fullVideoPath) else {
            throw RewindDataSourceError.videoFileNotFound(path: fullVideoPath)
        }

        let imageData = try extractFrameFromVideo(
            videoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )

        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        return imageData
    }

    private func extractFrameFromVideo(videoPath: String, frameIndex: Int, frameRate: Double) throws -> Data {
        // Rewind video files don't have extensions - create symlink with .mp4 extension
        let originalURL = URL(fileURLWithPath: videoPath)
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try FileManager.default.createSymbolicLink(at: tempURL, withDestinationURL: originalURL)
        } catch {
            throw RewindDataSourceError.frameExtractionFailed(underlying: "Failed to create temp symlink: \(error.localizedDescription)")
        }

        let asset = AVAsset(url: tempURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)

        let effectiveFrameRate = frameRate > 0 ? frameRate : 30.0
        let timeInSeconds = Double(frameIndex) / effectiveFrameRate
        let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)

        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapImage = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapImage.representation(
                    using: .jpeg,
                    properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.8]
                  ) else {
                throw RewindDataSourceError.imageConversionFailed
            }

            return jpegData
        } catch {
            throw RewindDataSourceError.frameExtractionFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - URL Bounding Box Detection (Delegated to Adapter)

    public func getURLBoundingBox(timestamp: Date) async throws -> URLBoundingBox? {
        guard _isConnected, let adapter = adapter else {
            throw DataSourceError.notConnected
        }

        return try await adapter.getURLBoundingBox(timestamp: timestamp)
    }

    // MARK: - App Discovery (Delegated to Adapter)

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

// MARK: - Rewind-Specific Errors

public enum RewindDataSourceError: Error, LocalizedError {
    case databaseNotFound(path: String)
    case connectionFailed(underlying: String)
    case videoFileNotFound(path: String)
    case frameExtractionFailed(underlying: String)
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Rewind database not found at: \(path)"
        case .connectionFailed(let error):
            return "Failed to connect to Rewind database: \(error)"
        case .videoFileNotFound(let path):
            return "Video file not found: \(path)"
        case .frameExtractionFailed(let error):
            return "Failed to extract frame from video: \(error)"
        case .imageConversionFailed:
            return "Failed to convert image to JPEG"
        }
    }
}
