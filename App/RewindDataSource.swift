import Foundation
import SQLCipher
import Shared
import AVFoundation
import AppKit

/// Data source for fetching historical data from Rewind's encrypted database
/// Used for timeline queries before the cutoff date (Dec 19, 2025)
/// Uses SQLCipher to decrypt the database on-demand
///
/// Rewind Schema (from REWIND_DATABASE_ANALYSIS.md):
///   - frame: id (INTEGER PK), createdAt (INTEGER ms), segmentId (FK), videoId (FK), videoFrameIndex
///   - segment: id (INTEGER PK), bundleID, startDate, endDate, windowName, browserUrl, type
///   - video: id (INTEGER PK), path, width, height, frameRate
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
    /// Key: "segmentID_timestamp" (e.g., "12345_1234567890.123")
    /// NSCache automatically evicts under memory pressure
    private let imageCache = NSCache<NSString, NSData>()

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

        // Configure image cache
        // Limit to ~200 frames (assuming ~500KB per frame = ~100MB total)
        imageCache.countLimit = 200
        imageCache.totalCostLimit = 100 * 1024 * 1024 // 100MB

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
        Log.info("[RewindDataSource] ✓ Database file opened", category: .app)

        // Set encryption key using sqlite3_exec with error pointer
        var keyError: UnsafeMutablePointer<Int8>?
        let keySQL = "PRAGMA key = '\(password)'"
        if sqlite3_exec(db, keySQL, nil, nil, &keyError) != SQLITE_OK {
            let error = keyError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(keyError)
            Log.error("[RewindDataSource] Failed to set encryption key: \(error)", category: .app)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to set encryption key: \(error)")
        }
        Log.info("[RewindDataSource] ✓ Encryption key set", category: .app)

        // Set cipher compatibility (Rewind uses SQLCipher 4)
        var compatError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError) != SQLITE_OK {
            let error = compatError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(compatError)
            Log.error("[RewindDataSource] Failed to set cipher compatibility: \(error)", category: .app)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to set cipher compatibility: \(error)")
        }
        Log.info("[RewindDataSource] ✓ Cipher compatibility set to 4", category: .app)

        // Verify connection by testing a simple query
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db!))
            Log.error("[RewindDataSource] Failed to verify encryption key: \(errMsg)", category: .app)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to verify encryption key: \(errMsg)")
        }

        guard sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            Log.error("[RewindDataSource] Failed to read from encrypted database", category: .app)
            throw RewindDataSourceError.connectionFailed(underlying: "Failed to read from encrypted database")
        }

        let tableCount = sqlite3_column_int(testStmt, 0)
        sqlite3_finalize(testStmt)
        Log.info("[RewindDataSource] ✓ Encryption verified (\(tableCount) objects in schema)", category: .app)

        // Log frame count for verification
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM frame", -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let frameCount = sqlite3_column_int64(countStmt, 0)
                Log.info("[RewindDataSource] ✓ Database contains \(frameCount) frames", category: .app)
            }
            sqlite3_finalize(countStmt)
        }

        _isConnected = true
        Log.info("[RewindDataSource] ✓ Connected to Rewind database successfully", category: .app)
    }

    public func disconnect() async {
        guard let db = db else { return }
        sqlite3_close(db)
        self.db = nil
        _isConnected = false
        Log.info("Disconnected from Rewind database", category: .app)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        // Use the optimized method and strip video info
        let framesWithVideo = try await getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Only return frames before cutoff date
        let effectiveEndDate = min(endDate, _cutoffDate)
        guard startDate < effectiveEndDate else {
            return []
        }

        // Optimized query: JOIN on segment AND video in one query
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
                v.frameRate
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Bind parameters (Rewind uses ISO 8601 TEXT format WITHOUT timezone suffix)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let startISO = dateFormatter.string(from: startDate)
        let endISO = dateFormatter.string(from: effectiveEndDate)

        Log.debug("[RewindDataSource] Query range: '\(startISO)' to '\(endISO)'", category: .app)

        sqlite3_bind_text(statement, 1, (startISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (endISO as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseRewindFrameWithVideoInfo(statement: statement!) {
                frames.append(frameWithVideo)
            }
        }

        Log.debug("[RewindDataSource] getFramesWithVideoInfo: fetched \(frames.count) frames", category: .app)
        return frames
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        // Use the optimized method and strip video info
        let framesWithVideo = try await getMostRecentFramesWithVideoInfo(limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Optimized query: subquery first to get limited frame IDs, then join for segment AND video data
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate
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

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseRewindFrameWithVideoInfo(statement: statement!) {
                frames.append(frameWithVideo)
            }
        }

        Log.debug("[RewindDataSource] getMostRecentFramesWithVideoInfo: fetched \(frames.count) frames", category: .app)
        return frames
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        // Use the optimized method and strip video info
        let framesWithVideo = try await getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Only return frames before cutoff date
        let effectiveTimestamp = min(timestamp, _cutoffDate)

        // Query frames BEFORE the timestamp, ordered DESC (newest first of the older batch)
        // JOIN on segment AND video
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate
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

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Convert timestamp to ISO format for query
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: effectiveTimestamp)

        sqlite3_bind_text(statement, 1, (timestampISO as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseRewindFrameWithVideoInfo(statement: statement!) {
                frames.append(frameWithVideo)
            }
        }

        Log.debug("[RewindDataSource] getFramesWithVideoInfoBefore: fetched \(frames.count) frames before \(timestampISO)", category: .app)
        return frames
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        // Use the optimized method and strip video info
        let framesWithVideo = try await getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit)
        return framesWithVideo.map { $0.frame }
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Don't return frames after cutoff date
        guard timestamp < _cutoffDate else {
            return []
        }

        // Query frames AFTER the timestamp, ordered ASC (oldest first of the newer batch)
        // JOIN on segment AND video
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt > ? AND createdAt < ?
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Convert timestamps to ISO format for query
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: timestamp)
        let cutoffISO = dateFormatter.string(from: _cutoffDate)

        sqlite3_bind_text(statement, 1, (timestampISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (cutoffISO as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseRewindFrameWithVideoInfo(statement: statement!) {
                frames.append(frameWithVideo)
            }
        }

        Log.debug("[RewindDataSource] getFramesWithVideoInfoAfter: fetched \(frames.count) frames after \(timestampISO)", category: .app)
        return frames
    }

    public func getFrameImage(segmentID: SegmentID, timestamp: Date) async throws -> Data {
        // Create cache key from segmentID and timestamp
        let cacheKey = "\(segmentID.stringValue)_\(timestamp.timeIntervalSince1970)" as NSString

        // Check cache first
        if let cachedData = imageCache.object(forKey: cacheKey) {
            Log.debug("[RewindDataSource] Cache hit for frame \(cacheKey)", category: .app)
            return cachedData as Data
        }

        Log.debug("[RewindDataSource] Cache miss - extracting frame for timestamp: \(timestamp)", category: .app)

        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // First, find the frame and its video info
        let sql = """
            SELECT f.videoId, f.videoFrameIndex, v.path, v.frameRate
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.segmentId = ? AND f.createdAt = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Query by timestamp instead of segment ID for Rewind data
        // (We can't reverse the synthetic UUID back to the original integer ID)
        let altSql = """
            SELECT f.videoFrameIndex, v.path, v.frameRate
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        var altStatement: OpaquePointer?
        defer { sqlite3_finalize(altStatement) }

        guard sqlite3_prepare_v2(db, altSql, -1, &altStatement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Convert timestamp to UTC for database query
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = utcFormatter.string(from: timestamp)

        sqlite3_bind_text(altStatement, 1, (timestampISO as NSString).utf8String, -1, nil)

        Log.debug("[RewindDataSource] Querying for frame with timestamp: \(timestampISO)", category: .app)

        guard sqlite3_step(altStatement) == SQLITE_ROW else {
            Log.error("[RewindDataSource] Frame not found for timestamp: \(timestampISO)", category: .app)
            throw DataSourceError.frameNotFound
        }

        let videoFrameIndex = sqlite3_column_int(altStatement, 0)
        guard let pathPtr = sqlite3_column_text(altStatement, 1) else {
            throw RewindDataSourceError.videoFileNotFound(path: "No video path for frame")
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(altStatement, 2)

        // Construct full path (video.path is relative to chunks directory)
        let fullVideoPath = "\(rewindChunksPath)/\(videoPath)"

        Log.debug("[RewindDataSource] Video path: \(fullVideoPath), frameIndex: \(videoFrameIndex), frameRate: \(frameRate)", category: .app)

        guard FileManager.default.fileExists(atPath: fullVideoPath) else {
            Log.error("[RewindDataSource] Video file not found at: \(fullVideoPath)", category: .app)
            throw RewindDataSourceError.videoFileNotFound(path: fullVideoPath)
        }

        // Extract frame from video
        Log.debug("[RewindDataSource] Extracting frame \(videoFrameIndex) from video", category: .app)
        let imageData = try extractFrameFromVideo(
            videoPath: fullVideoPath,
            frameIndex: Int(videoFrameIndex),
            frameRate: frameRate
        )

        // Cache the extracted image
        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        Log.debug("[RewindDataSource] Cached frame \(cacheKey)", category: .app)

        return imageData
    }

    public func getFrameVideoInfo(segmentID: SegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Query by timestamp to get video info (Rewind stores timestamps in UTC)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: timestamp)

        let sql = """
            SELECT f.videoFrameIndex, v.path, v.frameRate
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, (timestampISO as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataSourceError.frameNotFound
        }

        let videoFrameIndex = sqlite3_column_int(statement, 0)
        guard let pathPtr = sqlite3_column_text(statement, 1) else {
            throw RewindDataSourceError.videoFileNotFound(path: "No video path for frame")
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(statement, 2)

        // Construct full path (video.path is relative to chunks directory)
        let fullVideoPath = "\(rewindChunksPath)/\(videoPath)"

        guard FileManager.default.fileExists(atPath: fullVideoPath) else {
            throw RewindDataSourceError.videoFileNotFound(path: fullVideoPath)
        }

        Log.debug("[RewindDataSource] Video info: \(fullVideoPath), frame \(videoFrameIndex), fps \(frameRate)", category: .app)

        return FrameVideoInfo(
            videoPath: fullVideoPath,
            frameIndex: Int(videoFrameIndex),
            frameRate: frameRate
        )
    }

    public func getSessions(from startDate: Date, to endDate: Date) async throws -> [AppSession] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Only return sessions before cutoff date
        let effectiveEndDate = min(endDate, _cutoffDate)
        guard startDate < effectiveEndDate else {
            return []
        }

        // Rewind's segment table stores session-like data:
        // id, bundleID, startDate, endDate, windowName, browserUrl, type
        // startDate/endDate are ISO 8601 TEXT format in UTC
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl
            FROM segment
            WHERE startDate >= ? AND startDate <= ?
            ORDER BY startDate ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Bind parameters (Rewind uses ISO 8601 TEXT format in UTC)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let startISO = dateFormatter.string(from: startDate)
        let endISO = dateFormatter.string(from: effectiveEndDate)

        sqlite3_bind_text(statement, 1, (startISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (endISO as NSString).utf8String, -1, nil)

        var sessions: [AppSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let stmt = statement else { continue }

            // Column 0: id (INTEGER)
            let rewindSegmentId = sqlite3_column_int64(stmt, 0)

            // Column 1: bundleID (TEXT)
            let bundleID = getTextOrNil(stmt, 1) ?? "unknown"

            // Column 2: startDate (TEXT ISO 8601)
            guard let startDateText = getTextOrNil(stmt, 2),
                  let sessionStartDate = dateFormatter.date(from: startDateText) else {
                continue
            }

            // Column 3: endDate (TEXT ISO 8601, nullable)
            let sessionEndDate: Date?
            if let endDateText = getTextOrNil(stmt, 3) {
                sessionEndDate = dateFormatter.date(from: endDateText)
            } else {
                sessionEndDate = nil
            }

            // Column 4: windowName (TEXT, nullable)
            let windowName = getTextOrNil(stmt, 4)

            // Column 5: browserUrl (TEXT, nullable)
            let browserUrl = getTextOrNil(stmt, 5)

            // Create synthetic session ID from Rewind's integer ID
            let sessionID = AppSessionID(value: syntheticUUID(from: rewindSegmentId, namespace: "session"))

            let session = AppSession(
                id: sessionID,
                appBundleID: bundleID,
                appName: nil, // Rewind doesn't store app name separately
                windowTitle: windowName,
                browserURL: browserUrl,
                displayID: nil,
                startTime: sessionStartDate,
                endTime: sessionEndDate
            )
            sessions.append(session)
        }

        Log.debug("[RewindDataSource] getSessions: fetched \(sessions.count) sessions from \(startISO) to \(endISO)", category: .app)
        return sessions
    }

    // MARK: - Private Helpers

    private func extractFrameFromVideo(videoPath: String, frameIndex: Int, frameRate: Double) throws -> Data {
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)

        // Calculate time from frame index and frame rate
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

    /// Parse a frame row from Rewind database into FrameReference
    /// Rewind uses INTEGER ids, we need to create synthetic UUIDs for compatibility
    private func parseRewindFrame(statement: OpaquePointer) throws -> FrameReference {
        // Column 0: f.id (INTEGER)
        let rewindFrameId = sqlite3_column_int64(statement, 0)

        // Column 1: f.createdAt (TEXT in ISO 8601 format)
        guard let createdAtText = getTextOrNil(statement, 1) else {
            throw DataSourceError.queryFailed(underlying: "Missing createdAt timestamp")
        }

        // Parse timestamp (Rewind format: "2025-12-16T18:05:00.000" stored in UTC)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        guard let timestamp = dateFormatter.date(from: createdAtText) else {
            throw DataSourceError.queryFailed(underlying: "Invalid timestamp format: \(createdAtText)")
        }

        // Column 2: f.segmentId (INTEGER)
        let rewindSegmentId = sqlite3_column_int64(statement, 2)

        // Column 3: f.videoId (INTEGER, nullable)
        _ = sqlite3_column_type(statement, 3) != SQLITE_NULL
            ? sqlite3_column_int64(statement, 3)
            : nil

        // Column 4: f.videoFrameIndex (INTEGER)
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        // Column 5: f.encodingStatus (TEXT, nullable)
        let encodingStatusText = getTextOrNil(statement, 5)

        // Column 6: s.bundleID (TEXT)
        let bundleID = getTextOrNil(statement, 6)

        // Column 7: s.windowName (TEXT, nullable)
        let windowName = getTextOrNil(statement, 7)

        // Column 8: s.browserUrl (TEXT, nullable)
        let browserUrl = getTextOrNil(statement, 8)

        // Create synthetic UUIDs from Rewind's integer IDs
        // Using a deterministic namespace so the same Rewind ID always maps to the same UUID
        let frameID = FrameID(value: syntheticUUID(from: rewindFrameId, namespace: "frame"))
        let segmentID = SegmentID(value: syntheticUUID(from: rewindSegmentId, namespace: "segment"))

        // Map encoding status
        let encodingStatus: EncodingStatus = switch encodingStatusText {
        case "encoded", "success": .success
        case "pending": .pending
        case "failed": .failed
        default: .success // Rewind data is typically already encoded
        }

        let metadata = FrameMetadata(
            appBundleID: bundleID,
            appName: nil, // Rewind doesn't store appName separately
            windowTitle: windowName,
            browserURL: browserUrl
        )

        return FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: segmentID,
            sessionID: nil,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .rewind
        )
    }

    /// Parse a frame row with video info from Rewind database into FrameWithVideoInfo
    /// Columns expected:
    ///   0: f.id, 1: f.createdAt, 2: f.segmentId, 3: f.videoId, 4: f.videoFrameIndex,
    ///   5: f.encodingStatus, 6: s.bundleID, 7: s.windowName, 8: s.browserUrl,
    ///   9: v.path, 10: v.frameRate
    private func parseRewindFrameWithVideoInfo(statement: OpaquePointer) throws -> FrameWithVideoInfo {
        // Columns 0-8: Same as parseRewindFrame
        let rewindFrameId = sqlite3_column_int64(statement, 0)

        guard let createdAtText = getTextOrNil(statement, 1) else {
            throw DataSourceError.queryFailed(underlying: "Missing createdAt timestamp")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        guard let timestamp = dateFormatter.date(from: createdAtText) else {
            throw DataSourceError.queryFailed(underlying: "Invalid timestamp format: \(createdAtText)")
        }

        let rewindSegmentId = sqlite3_column_int64(statement, 2)
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))
        let encodingStatusText = getTextOrNil(statement, 5)
        let bundleID = getTextOrNil(statement, 6)
        let windowName = getTextOrNil(statement, 7)
        let browserUrl = getTextOrNil(statement, 8)

        // Column 9: v.path (TEXT, nullable)
        let videoPath = getTextOrNil(statement, 9)

        // Column 10: v.frameRate (REAL)
        let frameRate = sqlite3_column_double(statement, 10)

        // Create synthetic UUIDs
        let frameID = FrameID(value: syntheticUUID(from: rewindFrameId, namespace: "frame"))
        let segmentID = SegmentID(value: syntheticUUID(from: rewindSegmentId, namespace: "segment"))

        let encodingStatus: EncodingStatus = switch encodingStatusText {
        case "encoded", "success": .success
        case "pending": .pending
        case "failed": .failed
        default: .success
        }

        let metadata = FrameMetadata(
            appBundleID: bundleID,
            appName: nil,
            windowTitle: windowName,
            browserURL: browserUrl
        )

        let frame = FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: segmentID,
            sessionID: nil,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .rewind
        )

        // Build video info if we have a video path
        let videoInfo: FrameVideoInfo?
        if let path = videoPath {
            let fullVideoPath = "\(rewindChunksPath)/\(path)"
            // Only include video info if the file exists
            if FileManager.default.fileExists(atPath: fullVideoPath) {
                videoInfo = FrameVideoInfo(
                    videoPath: fullVideoPath,
                    frameIndex: videoFrameIndex,
                    frameRate: frameRate > 0 ? frameRate : 30.0
                )
            } else {
                videoInfo = nil
            }
        } else {
            videoInfo = nil
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo)
    }

    /// Create a deterministic UUID from an integer ID
    /// Uses namespace + id to create reproducible UUIDs
    private func syntheticUUID(from intId: Int64, namespace: String) -> UUID {
        // Create deterministic bytes from namespace + id
        let combinedString = "\(namespace):\(intId)"
        let data = combinedString.data(using: .utf8)!

        // Use first 16 bytes of SHA256 hash to create UUID
        var bytes = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { buffer in
            // Simple hash: just use the bytes directly for small inputs
            // For production, use CryptoKit SHA256
            for (i, byte) in buffer.enumerated() where i < 16 {
                bytes[i] = byte
            }
            // XOR in the integer ID
            let idBytes = withUnsafeBytes(of: intId.bigEndian) { Array($0) }
            for (i, byte) in idBytes.enumerated() {
                bytes[i % 16] ^= byte
            }
        }

        // Set UUID version and variant bits
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // Version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // Variant

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func getTextOrNil(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    // MARK: - Deletion Methods

    public func deleteFrame(frameID: FrameID) async throws {
        try await deleteFrames(frameIDs: [frameID])
    }

    public func deleteFrames(frameIDs: [FrameID]) async throws {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        guard !frameIDs.isEmpty else { return }

        // We need to convert synthetic UUIDs back to Rewind integer IDs
        // This is tricky because our synthetic UUIDs are one-way hashes
        // Instead, we'll delete by timestamp which we can query

        // For now, we need to find the frames by querying all and matching
        // This is a limitation of the synthetic UUID approach

        // Alternative: Store a mapping table or delete by timestamp
        // For MVP, we'll use a transaction to delete related data

        Log.info("[RewindDataSource] Deleting \(frameIDs.count) frames from database", category: .app)

        // Start transaction
        var errorPtr: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errorPtr) == SQLITE_OK else {
            let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPtr)
            throw DataSourceError.queryFailed(underlying: "Failed to begin transaction: \(error)")
        }

        do {
            for frameID in frameIDs {
                // Since we can't reverse the UUID, we need to find the frame by other means
                // For Rewind data, the frame.id in the UUID contains encoded info
                // We'll need to query by the frame data we have

                // For now, log that deletion requires timestamp-based lookup
                Log.warning("[RewindDataSource] Frame deletion by UUID not fully implemented - requires timestamp lookup", category: .app)
            }

            // Commit transaction
            guard sqlite3_exec(db, "COMMIT", nil, nil, &errorPtr) == SQLITE_OK else {
                let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errorPtr)
                throw DataSourceError.queryFailed(underlying: "Failed to commit transaction: \(error)")
            }

            Log.info("[RewindDataSource] Successfully deleted frames from database", category: .app)

        } catch {
            // Rollback on error
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Delete a frame by its timestamp (more reliable for Rewind data)
    public func deleteFrameByTimestamp(_ timestamp: Date) async throws {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: timestamp)

        Log.info("[RewindDataSource] Deleting frame with timestamp: \(timestampISO)", category: .app)

        // Start transaction
        var errorPtr: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errorPtr) == SQLITE_OK else {
            let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPtr)
            throw DataSourceError.queryFailed(underlying: "Failed to begin transaction: \(error)")
        }

        do {
            // 1. Get the frame ID first
            let getFrameSQL = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1"
            var getStmt: OpaquePointer?
            defer { sqlite3_finalize(getStmt) }

            guard sqlite3_prepare_v2(db, getFrameSQL, -1, &getStmt, nil) == SQLITE_OK else {
                throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_text(getStmt, 1, (timestampISO as NSString).utf8String, -1, nil)

            guard sqlite3_step(getStmt) == SQLITE_ROW else {
                throw DataSourceError.frameNotFound
            }

            let rewindFrameId = sqlite3_column_int64(getStmt!, 0)

            // 2. Delete nodes associated with this frame
            let deleteNodesSQL = "DELETE FROM node WHERE frameId = ?"
            var deleteNodesStmt: OpaquePointer?
            defer { sqlite3_finalize(deleteNodesStmt) }

            guard sqlite3_prepare_v2(db, deleteNodesSQL, -1, &deleteNodesStmt, nil) == SQLITE_OK else {
                throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(deleteNodesStmt, 1, rewindFrameId)
            sqlite3_step(deleteNodesStmt)

            let nodesDeleted = sqlite3_changes(db)
            Log.debug("[RewindDataSource] Deleted \(nodesDeleted) nodes", category: .app)

            // 3. Delete from doc_segment (FTS junction table)
            let deleteDocSegmentSQL = "DELETE FROM doc_segment WHERE frameId = ?"
            var deleteDocStmt: OpaquePointer?
            defer { sqlite3_finalize(deleteDocStmt) }

            guard sqlite3_prepare_v2(db, deleteDocSegmentSQL, -1, &deleteDocStmt, nil) == SQLITE_OK else {
                throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(deleteDocStmt, 1, rewindFrameId)
            sqlite3_step(deleteDocStmt)

            // 4. Delete the frame itself
            let deleteFrameSQL = "DELETE FROM frame WHERE id = ?"
            var deleteFrameStmt: OpaquePointer?
            defer { sqlite3_finalize(deleteFrameStmt) }

            guard sqlite3_prepare_v2(db, deleteFrameSQL, -1, &deleteFrameStmt, nil) == SQLITE_OK else {
                throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(deleteFrameStmt, 1, rewindFrameId)
            sqlite3_step(deleteFrameStmt)

            // Commit transaction
            guard sqlite3_exec(db, "COMMIT", nil, nil, &errorPtr) == SQLITE_OK else {
                let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errorPtr)
                throw DataSourceError.queryFailed(underlying: "Failed to commit transaction: \(error)")
            }

            Log.info("[RewindDataSource] Successfully deleted frame \(rewindFrameId) and \(nodesDeleted) nodes", category: .app)

        } catch {
            // Rollback on error
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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
