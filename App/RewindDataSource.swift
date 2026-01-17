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

        // Query frames AT OR AFTER the timestamp, ordered ASC (oldest first of the newer batch)
        // Note: Using >= to include the exact timestamp frame (important for search navigation)
        // JOIN on segment AND video
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt >= ? AND createdAt < ?
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

    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
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

    /// Get frame image by exact videoID and frameIndex (more reliable than timestamp matching)
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        // Create cache key from videoID and frameIndex
        let cacheKey = "\(videoID.stringValue)_\(frameIndex)" as NSString

        // Check cache first
        if let cachedData = imageCache.object(forKey: cacheKey) {
            Log.debug("[RewindDataSource] Cache hit for frame \(cacheKey)", category: .app)
            return cachedData as Data
        }

        Log.debug("[RewindDataSource] Cache miss - extracting frame \(frameIndex) from video \(videoID.stringValue)", category: .app)

        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Query video info by videoID (exact match, no timestamp issues)
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
            Log.error("[RewindDataSource] Video not found for videoID: \(videoID.stringValue)", category: .app)
            throw DataSourceError.frameNotFound
        }

        guard let pathPtr = sqlite3_column_text(statement, 0) else {
            throw RewindDataSourceError.videoFileNotFound(path: "No video path for videoID \(videoID.stringValue)")
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(statement, 1)

        // Construct full path (video.path is relative to chunks directory)
        let fullVideoPath = "\(rewindChunksPath)/\(videoPath)"

        Log.debug("[RewindDataSource] Video path: \(fullVideoPath), frameIndex: \(frameIndex), frameRate: \(frameRate)", category: .app)

        guard FileManager.default.fileExists(atPath: fullVideoPath) else {
            Log.error("[RewindDataSource] Video file not found at: \(fullVideoPath)", category: .app)
            throw RewindDataSourceError.videoFileNotFound(path: fullVideoPath)
        }

        // Extract frame from video
        Log.debug("[RewindDataSource] Extracting frame \(frameIndex) from video", category: .app)
        let imageData = try extractFrameFromVideo(
            videoPath: fullVideoPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )

        // Cache the extracted image
        imageCache.setObject(imageData as NSData, forKey: cacheKey)
        Log.debug("[RewindDataSource] Cached frame \(cacheKey)", category: .app)

        return imageData
    }

    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date) async throws -> FrameVideoInfo? {
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

        // Log.debug("[RewindDataSource] Video info: \(fullVideoPath), frame \(videoFrameIndex), fps \(frameRate)", category: .app)

        return FrameVideoInfo(
            videoPath: fullVideoPath,
            frameIndex: Int(videoFrameIndex),
            frameRate: frameRate
        )
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Only return segments before cutoff date
        let effectiveEndDate = min(endDate, _cutoffDate)
        guard startDate < effectiveEndDate else {
            return []
        }

        // Rewind's segment table stores app focus session data:
        // id, bundleID, startDate, endDate, windowName, browserUrl, type
        // startDate/endDate are ISO 8601 TEXT format in UTC
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
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

        var segments: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let stmt = statement else { continue }

            // Column 0: id (INTEGER)
            let rewindSegmentId = sqlite3_column_int64(stmt, 0)

            // Column 1: bundleID (TEXT)
            let bundleID = getTextOrNil(stmt, 1) ?? "unknown"

            // Column 2: startDate (TEXT ISO 8601)
            guard let startDateText = getTextOrNil(stmt, 2),
                  let segmentStartDate = dateFormatter.date(from: startDateText) else {
                continue
            }

            // Column 3: endDate (TEXT ISO 8601)
            guard let endDateText = getTextOrNil(stmt, 3),
                  let segmentEndDate = dateFormatter.date(from: endDateText) else {
                continue
            }

            // Column 4: windowName (TEXT, nullable)
            let windowName = getTextOrNil(stmt, 4)

            // Column 5: browserUrl (TEXT, nullable)
            let browserUrl = getTextOrNil(stmt, 5)

            // Column 6: type (INTEGER)
            let type = Int(sqlite3_column_int(stmt, 6))

            let segment = Segment(
                id: SegmentID(value: rewindSegmentId),
                bundleID: bundleID,
                startDate: segmentStartDate,
                endDate: segmentEndDate,
                windowName: windowName,
                browserUrl: browserUrl,
                type: type
            )
            segments.append(segment)
        }

        Log.debug("[RewindDataSource] getSegments: fetched \(segments.count) segments from \(startISO) to \(endISO)", category: .app)
        return segments
    }

    // MARK: - Private Helpers

    private func extractFrameFromVideo(videoPath: String, frameIndex: Int, frameRate: Double) throws -> Data {
        // Rewind video files don't have extensions, but AVAssetImageGenerator needs .mp4 extension
        // to properly identify the file type. Create a temporary symlink with .mp4 extension.
        let originalURL = URL(fileURLWithPath: videoPath)
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")

        defer {
            // Clean up the temporary symlink
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try FileManager.default.createSymbolicLink(at: tempURL, withDestinationURL: originalURL)
        } catch {
            Log.error("[RewindDataSource] Failed to create temp symlink: \(error)", category: .app)
            throw RewindDataSourceError.frameExtractionFailed(underlying: "Failed to create temp symlink: \(error.localizedDescription)")
        }

        let asset = AVAsset(url: tempURL)
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
    /// Now uses Int64 IDs directly from Rewind - no UUID conversion needed!
    private func parseRewindFrame(statement: OpaquePointer) throws -> FrameReference {
        // Column 0: f.id (INTEGER)
        let frameId = sqlite3_column_int64(statement, 0)

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

        // Column 2: f.segmentId (INTEGER) - Rewind's app segment (session)
        let segmentId = sqlite3_column_int64(statement, 2)
        let appSegmentID = AppSegmentID(value: segmentId)

        // Column 3: f.videoId (INTEGER) - Rewind's video.id (video chunk)
        let videoId = sqlite3_column_int64(statement, 3)
        let videoSegmentID = VideoSegmentID(value: videoId)

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

        // Use Rewind's INTEGER frame ID directly (1:1 schema match!)
        let frameID = FrameID(value: frameId)

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
            windowName: windowName,
            browserURL: browserUrl
        )

        return FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: appSegmentID,  // Link to app session (segment table)
            videoID: videoSegmentID,  // Link to video chunk (video table)
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
        let frameId = sqlite3_column_int64(statement, 0)

        guard let createdAtText = getTextOrNil(statement, 1) else {
            throw DataSourceError.queryFailed(underlying: "Missing createdAt timestamp")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        guard let timestamp = dateFormatter.date(from: createdAtText) else {
            throw DataSourceError.queryFailed(underlying: "Invalid timestamp format: \(createdAtText)")
        }

        // Column 2: segmentId (INTEGER) - Rewind's app segment (session)
        let segmentId = sqlite3_column_int64(statement, 2)
        let appSegmentID = AppSegmentID(value: segmentId)

        // Column 3: videoId (INTEGER) - Rewind's video.id (video chunk)
        let videoId = sqlite3_column_int64(statement, 3)
        let videoSegmentID = VideoSegmentID(value: videoId)

        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))
        let encodingStatusText = getTextOrNil(statement, 5)
        let bundleID = getTextOrNil(statement, 6)
        let windowName = getTextOrNil(statement, 7)
        let browserUrl = getTextOrNil(statement, 8)

        // Column 9: v.path (TEXT, nullable)
        let videoPath = getTextOrNil(statement, 9)

        // Column 10: v.frameRate (REAL)
        let frameRate = sqlite3_column_double(statement, 10)

        // Use Int64 frame ID directly
        let frameID = FrameID(value: frameId)

        let encodingStatus: EncodingStatus = switch encodingStatusText {
        case "encoded", "success": .success
        case "pending": .pending
        case "failed": .failed
        default: .success
        }

        let metadata = FrameMetadata(
            appBundleID: bundleID,
            appName: nil,
            windowName: windowName,
            browserURL: browserUrl
        )

        let frame = FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: appSegmentID,  // Link to app session (segment table)
            videoID: videoSegmentID,  // Link to video chunk (video table)
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

        // Now that we use Int64 IDs directly, deletion is straightforward!
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
                let rewindFrameId = frameID.value

                // 1. Get the segment ID first
                let getSegmentSQL = "SELECT segmentId FROM frame WHERE id = ? LIMIT 1"
                var getStmt: OpaquePointer?
                defer { sqlite3_finalize(getStmt) }

                guard sqlite3_prepare_v2(db, getSegmentSQL, -1, &getStmt, nil) == SQLITE_OK else {
                    throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
                }

                sqlite3_bind_int64(getStmt, 1, rewindFrameId)

                guard sqlite3_step(getStmt) == SQLITE_ROW else {
                    Log.warning("[RewindDataSource] Frame \(rewindFrameId) not found, skipping", category: .app)
                    continue
                }

                let segmentId = sqlite3_column_int64(getStmt!, 0)

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

                Log.info("[RewindDataSource] Deleted frame \(rewindFrameId) and \(nodesDeleted) nodes", category: .app)
            }

            // Commit transaction
            guard sqlite3_exec(db, "COMMIT", nil, nil, &errorPtr) == SQLITE_OK else {
                let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errorPtr)
                throw DataSourceError.queryFailed(underlying: "Failed to commit transaction: \(error)")
            }

            Log.info("[RewindDataSource] Successfully deleted \(frameIDs.count) frames from database", category: .app)

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
            // 1. Get the frame ID and segment ID first
            let getFrameSQL = "SELECT id, segmentId FROM frame WHERE createdAt = ? LIMIT 1"
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
            let segmentId = sqlite3_column_int64(getStmt!, 1)

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

            // 5. Check if this segment now has no frames left
            let countFramesSQL = "SELECT COUNT(*) FROM frame WHERE segmentId = ?"
            var countStmt: OpaquePointer?
            defer { sqlite3_finalize(countStmt) }

            guard sqlite3_prepare_v2(db, countFramesSQL, -1, &countStmt, nil) == SQLITE_OK else {
                throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(countStmt, 1, segmentId)

            var segmentDeleted = false
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let remainingFrames = sqlite3_column_int64(countStmt!, 0)
                if remainingFrames == 0 {
                    // No frames left in this segment, delete the segment too
                    let deleteSegmentSQL = "DELETE FROM segment WHERE id = ?"
                    var deleteSegmentStmt: OpaquePointer?
                    defer { sqlite3_finalize(deleteSegmentStmt) }

                    guard sqlite3_prepare_v2(db, deleteSegmentSQL, -1, &deleteSegmentStmt, nil) == SQLITE_OK else {
                        throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
                    }
                    sqlite3_bind_int64(deleteSegmentStmt, 1, segmentId)
                    sqlite3_step(deleteSegmentStmt)
                    segmentDeleted = true
                    Log.info("[RewindDataSource] Deleted empty segment \(segmentId)", category: .app)
                }
            }

            // Commit transaction
            guard sqlite3_exec(db, "COMMIT", nil, nil, &errorPtr) == SQLITE_OK else {
                let error = errorPtr.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errorPtr)
                throw DataSourceError.queryFailed(underlying: "Failed to commit transaction: \(error)")
            }

            if segmentDeleted {
                Log.info("[RewindDataSource] Successfully deleted frame \(rewindFrameId), \(nodesDeleted) nodes, and segment \(segmentId)", category: .app)
            } else {
                Log.info("[RewindDataSource] Successfully deleted frame \(rewindFrameId) and \(nodesDeleted) nodes", category: .app)
            }

        } catch {
            // Rollback on error
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - URL Bounding Box Detection

    /// Represents a bounding box for a URL found on screen
    public struct URLBoundingBox {
        /// Normalized X coordinate (0.0-1.0)
        public let x: CGFloat
        /// Normalized Y coordinate (0.0-1.0)
        public let y: CGFloat
        /// Normalized width (0.0-1.0)
        public let width: CGFloat
        /// Normalized height (0.0-1.0)
        public let height: CGFloat
        /// The URL string
        public let url: String
    }

    /// Find the bounding box of a URL on screen for a given frame timestamp
    /// Returns the bounding box if the URL text is found in the OCR nodes
    public func getURLBoundingBox(timestamp: Date) async throws -> URLBoundingBox? {
        guard _isConnected, let db = db else {
            print("[URLBoundingBox] ERROR: Database not connected")
            throw DataSourceError.notConnected
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: timestamp)

        print("[URLBoundingBox] Looking up frame for timestamp: \(timestampISO)")

        // 1. Get frameId and browserUrl from frame + segment join
        let frameSQL = """
            SELECT f.id, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        var frameStmt: OpaquePointer?
        defer { sqlite3_finalize(frameStmt) }

        guard sqlite3_prepare_v2(db, frameSQL, -1, &frameStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(frameStmt, 1, (timestampISO as NSString).utf8String, -1, nil)

        guard sqlite3_step(frameStmt) == SQLITE_ROW else {
            print("[URLBoundingBox] Frame not found for timestamp")
            return nil // Frame not found
        }

        let frameId = sqlite3_column_int64(frameStmt!, 0)
        guard let browserUrlPtr = sqlite3_column_text(frameStmt!, 1) else {
            return nil // No browser URL for this segment
        }
        let browserUrl = String(cString: browserUrlPtr)

        // Skip empty URLs
        guard !browserUrl.isEmpty else {
            return nil
        }

        // 2. Get the FTS content text for this frame to find URL position
        // Note: c0 and c1 usage varies across frames - sometimes c0 has main OCR, sometimes c1
        // We need to use whichever column has the content that matches the node offsets
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        var ftsStmt: OpaquePointer?
        defer { sqlite3_finalize(ftsStmt) }

        guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else {
            return nil // No FTS content
        }

        // Get both columns and CONCATENATE them
        // Node textOffset values index into the concatenated string: c0 || c1
        // c0 typically contains the browser URL, c1 contains the OCR text
        // Offsets 0 to len(c0)-1 reference c0, offsets len(c0)+ reference c1
        let c0Text = sqlite3_column_text(ftsStmt!, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt!, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text

        // 3. Extract domain/host from URL for matching (browsers often show just the domain)
        let urlComponents = extractURLComponents(browserUrl)

        // 4. Get all nodes for this frame
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        var nodesStmt: OpaquePointer?
        defer { sqlite3_finalize(nodesStmt) }

        guard sqlite3_prepare_v2(db, nodesSQL, -1, &nodesStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        // 5. Find the node that contains the URL in the address bar
        var bestMatch: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?

        // Extract just the domain for matching
        let domain = URL(string: browserUrl)?.host ?? browserUrl

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let textOffset = Int(sqlite3_column_int(nodesStmt!, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt!, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt!, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt!, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt!, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt!, 6))

            // Extract the text for this node from the FTS content
            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])

            // Check if this node contains the domain
            guard nodeText.lowercased().contains(domain.lowercased()) else { continue }

            // Score based on how much the node looks like a URL bar vs page content
            var score = 0

            // The address bar typically contains JUST the URL or domain+path
            // Tab titles contain the domain + page title (extra words)
            // Prefer nodes where URL/domain is a larger portion of the text
            let urlRatio = Double(domain.count) / Double(nodeText.count)
            if urlRatio > 0.6 {
                score += 100  // Very URL-like (e.g., "f.inc/smash" -> f.inc is 62% of text)
            } else if urlRatio > 0.3 {
                score += 50   // Somewhat URL-like
            } else {
                score += 10   // Probably page title or content (e.g., "f.inc Smash Leaderboard")
            }

            // Address bar is typically around y=0.08-0.12 (below tabs at ~0.05)
            // Tabs are at y=0.05, address bar is lower
            if topY > 0.07 && topY < 0.15 {
                score += 50   // In address bar region
            } else if topY < 0.07 {
                score += 20   // Might be tab title
            }

            // Prefer nodes that look like URLs (contain / or .)
            if nodeText.contains("/") && !nodeText.contains(" ") {
                score += 30   // Looks like a URL path with no spaces
            }

            if let current = bestMatch {
                if score > current.score {
                    bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
                }
            } else {
                bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
            }
        }

        guard let bounds = bestMatch else {
            return nil // URL text not found in OCR
        }

        return URLBoundingBox(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            url: browserUrl
        )
    }

    // MARK: - OCR Node Detection (for text selection)

    /// Legacy type alias - now uses shared OCRNodeWithText from Shared module
    public typealias OCRNode = OCRNodeWithText

    /// Get all OCR nodes for a given frame timestamp
    /// Returns array of nodes with their bounding boxes and text content
    /// Used for text selection highlighting feature
    public func getAllOCRNodes(timestamp: Date) async throws -> [OCRNode] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let timestampISO = dateFormatter.string(from: timestamp)

        // 1. Get frameId from frame table
        let frameSQL = """
            SELECT f.id
            FROM frame f
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        var frameStmt: OpaquePointer?
        defer { sqlite3_finalize(frameStmt) }

        guard sqlite3_prepare_v2(db, frameSQL, -1, &frameStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(frameStmt, 1, (timestampISO as NSString).utf8String, -1, nil)

        guard sqlite3_step(frameStmt) == SQLITE_ROW else {
            return [] // Frame not found
        }

        let frameId = sqlite3_column_int64(frameStmt!, 0)

        // 2. Get the FTS content text for this frame (concatenate c0 and c1)
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        var ftsStmt: OpaquePointer?
        defer { sqlite3_finalize(ftsStmt) }

        guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else {
            return [] // No FTS content
        }

        // Concatenate c0 and c1 - node textOffset indexes into this combined string
        let c0Text = sqlite3_column_text(ftsStmt!, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt!, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text

        // 3. Get all nodes for this frame
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        var nodesStmt: OpaquePointer?
        defer { sqlite3_finalize(nodesStmt) }

        guard sqlite3_prepare_v2(db, nodesSQL, -1, &nodesStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        // 4. Extract all nodes with their text
        var nodes: [OCRNode] = []

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let nodeOrder = Int(sqlite3_column_int(nodesStmt!, 0))
            let textOffset = Int(sqlite3_column_int(nodesStmt!, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt!, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt!, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt!, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt!, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt!, 6))

            // Extract the text for this node from the FTS content
            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])

            // Skip empty text nodes
            guard !nodeText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            nodes.append(OCRNode(
                id: nodeOrder,
                x: leftX,
                y: topY,
                width: width,
                height: height,
                text: nodeText
            ))
        }

        return nodes
    }

    /// Get all OCR nodes for a given frame by frameID (more reliable than timestamp)
    /// Returns array of nodes with their bounding boxes and text content
    public func getAllOCRNodes(frameID: FrameID) async throws -> [OCRNode] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        let frameId = frameID.value

        // 1. Get the FTS content text for this frame (concatenate c0 and c1)
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        var ftsStmt: OpaquePointer?
        defer { sqlite3_finalize(ftsStmt) }

        guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else {
            return [] // No FTS content
        }

        // Concatenate c0 and c1 - node textOffset indexes into this combined string
        let c0Text = sqlite3_column_text(ftsStmt!, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt!, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text

        // 2. Get all nodes for this frame
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        var nodesStmt: OpaquePointer?
        defer { sqlite3_finalize(nodesStmt) }

        guard sqlite3_prepare_v2(db, nodesSQL, -1, &nodesStmt, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        // 3. Extract all nodes with their text
        var nodes: [OCRNode] = []

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let nodeOrder = Int(sqlite3_column_int(nodesStmt!, 0))
            let textOffset = Int(sqlite3_column_int(nodesStmt!, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt!, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt!, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt!, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt!, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt!, 6))

            // Extract the text for this node from the FTS content
            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])

            // Skip empty text nodes
            guard !nodeText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            nodes.append(OCRNode(
                id: nodeOrder,
                x: leftX,
                y: topY,
                width: width,
                height: height,
                text: nodeText
            ))
        }

        return nodes
    }

    /// Extract searchable components from a URL (domain, path segments)
    private func extractURLComponents(_ url: String) -> [String] {
        var components: [String] = []

        // Add full URL
        components.append(url)

        // Try to parse as URL
        if let parsed = URL(string: url) {
            // Add host/domain
            if let host = parsed.host {
                components.append(host)
                // Add domain without www
                if host.hasPrefix("www.") {
                    components.append(String(host.dropFirst(4)))
                }
            }

            // Add path if meaningful
            let path = parsed.path
            if !path.isEmpty && path != "/" {
                components.append(path)
                // Add last path component
                if let lastComponent = path.split(separator: "/").last {
                    components.append(String(lastComponent))
                }
            }
        }

        return components.filter { !$0.isEmpty }
    }

    // MARK: - Full-Text Search

    /// Search Rewind's OCR text using the searchRanking FTS5 table
    /// Supports two modes:
    /// - .relevant: Top 200 by BM25 relevance, then sorted by date (fast, best matches)
    /// - .all: All matches sorted by date using subquery (slower, chronological)
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard _isConnected, let database = db else {
            throw DataSourceError.notConnected
        }

        switch query.mode {
        case .relevant:
            return try await searchRelevant(query: query, database: database)
        case .all:
            return try await searchAll(query: query, database: database)
        }
    }

    /// Relevant search: Top N by BM25, then sorted by date
    /// Two-phase approach for speed
    private func searchRelevant(query: SearchQuery, database: OpaquePointer) async throws -> SearchResults {
        let startTime = Date()
        Log.info("[RewindSearch] Relevant search for: '\(query.text)' with filters: app=\(query.filters.appBundleIDs?.first ?? "all"), dates=\(query.filters.startDate != nil ? "yes" : "no")", category: .app)

        let ftsQuery = buildFTSQuery(query.text)
        Log.debug("[RewindSearch] FTS query: '\(ftsQuery)'", category: .app)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Phase 1: Pure FTS search - get top 50 by relevance
        let phase1Start = Date()
        let relevanceLimit = 50  // Cap relevant results
        let ftsSQL = """
            SELECT rowid, snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet, bm25(searchRanking) as rank
            FROM searchRanking
            WHERE searchRanking MATCH ?
            ORDER BY bm25(searchRanking)
            LIMIT ?
        """

        var ftsStatement: OpaquePointer?
        defer { sqlite3_finalize(ftsStatement) }

        guard sqlite3_prepare_v2(database, ftsSQL, -1, &ftsStatement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(database))
            Log.error("[RewindSearch] Failed to prepare FTS statement: \(error)", category: .app)
            throw DataSourceError.queryFailed(underlying: error)
        }

        sqlite3_bind_text(ftsStatement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(ftsStatement, 2, Int32(relevanceLimit))

        var ftsResults: [(rowid: Int64, snippet: String, rank: Double)] = []
        while sqlite3_step(ftsStatement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(ftsStatement, 0)
            let snippet = sqlite3_column_text(ftsStatement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(ftsStatement, 2)
            ftsResults.append((rowid: rowid, snippet: snippet, rank: rank))
        }

        let phase1Elapsed = Int(Date().timeIntervalSince(phase1Start) * 1000)
        Log.info("[RewindSearch] Phase 1 (FTS): Found \(ftsResults.count) matches in \(phase1Elapsed)ms", category: .app)

        guard !ftsResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: elapsed)
        }

        // Phase 2: Join to get metadata, sorted by date, with pagination and filters
        let phase2Start = Date()
        let rowids = ftsResults.map { $0.rowid }
        let rowidPlaceholders = rowids.map { _ in "?" }.joined(separator: ", ")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let cutoffISO = dateFormatter.string(from: _cutoffDate)

        // Build dynamic WHERE clause based on filters
        var whereConditions = ["ds.docid IN (\(rowidPlaceholders))", "f.createdAt < ?"]
        var extraBindValues: [Any] = [cutoffISO]

        // Date range filters
        if let startDate = query.filters.startDate {
            let startISO = dateFormatter.string(from: startDate)
            whereConditions.append("f.createdAt >= ?")
            extraBindValues.append(startISO)
        }
        if let endDate = query.filters.endDate {
            let endISO = dateFormatter.string(from: endDate)
            whereConditions.append("f.createdAt <= ?")
            extraBindValues.append(endISO)
        }

        // App filter
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

        var metaStatement: OpaquePointer?
        defer { sqlite3_finalize(metaStatement) }

        guard sqlite3_prepare_v2(database, metadataSQL, -1, &metaStatement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(database))
            Log.error("[RewindSearch] Failed to prepare metadata statement: \(error)", category: .app)
            throw DataSourceError.queryFailed(underlying: error)
        }

        // Bind rowids first
        var bindIndex: Int32 = 1
        for rowid in rowids {
            sqlite3_bind_int64(metaStatement, bindIndex, rowid)
            bindIndex += 1
        }

        // Bind extra values (cutoff date, filter dates, app bundle IDs)
        for value in extraBindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(metaStatement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            }
            bindIndex += 1
        }

        // Bind limit and offset
        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.offset))

        let ftsLookup = Dictionary(uniqueKeysWithValues: ftsResults.map { ($0.rowid, (snippet: $0.snippet, rank: $0.rank)) })

        var results: [SearchResult] = []

        while sqlite3_step(metaStatement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(metaStatement, 0)
            let frameId = sqlite3_column_int64(metaStatement, 1)
            let timestampStr = String(cString: sqlite3_column_text(metaStatement, 2))
            let segmentId = sqlite3_column_int64(metaStatement, 3)
            let appBundleID = sqlite3_column_text(metaStatement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(metaStatement, 5).map { String(cString: $0) }
            let videoId = sqlite3_column_int64(metaStatement, 6)
            let frameIndex = Int(sqlite3_column_int(metaStatement, 7))

            guard let ftsData = ftsLookup[docid] else { continue }
            let snippet = ftsData.snippet
            let rank = ftsData.rank

            let appName = appBundleID?.components(separatedBy: ".").last
            let parsedTimestamp = parseRewindTimestamp(timestampStr)
            let timestamp = parsedTimestamp ?? Date()

            // Use Int64 frame ID directly
            let frameID = FrameID(value: frameId)

            let cleanSnippet = snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: frameID,
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
                frameIndex: frameIndex
            )

            results.append(result)
        }

        let phase2Elapsed = Int(Date().timeIntervalSince(phase2Start) * 1000)
        let totalElapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        Log.info("[RewindSearch] Relevant search: \(results.count) results in \(totalElapsed)ms (phase1=\(phase1Elapsed)ms, phase2=\(phase2Elapsed)ms)", category: .app)

        // Total count is capped at relevanceLimit for this mode
        let totalCount = min(ftsResults.count, relevanceLimit)

        return SearchResults(
            query: query,
            results: results,
            totalCount: totalCount,
            searchTimeMs: totalElapsed
        )
    }

    /// All search: Chronological results using subquery for efficiency
    /// FTS filters first, then minimal joins for date sorting
    private func searchAll(query: SearchQuery, database: OpaquePointer) async throws -> SearchResults {
        let startTime = Date()
        Log.info("[RewindSearch] All search for: '\(query.text)' with filters: app=\(query.filters.appBundleIDs?.first ?? "all"), dates=\(query.filters.startDate != nil ? "yes" : "no")", category: .app)

        let ftsQuery = buildFTSQuery(query.text)
        Log.debug("[RewindSearch] FTS query: '\(ftsQuery)'", category: .app)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")!
        let cutoffISO = dateFormatter.string(from: _cutoffDate)

        // Build dynamic WHERE clause based on filters
        var whereConditions = ["f.createdAt < ?"]
        var bindValues: [Any] = [cutoffISO]

        // Date range filters
        if let startDate = query.filters.startDate {
            let startISO = dateFormatter.string(from: startDate)
            whereConditions.append("f.createdAt >= ?")
            bindValues.append(startISO)
        }
        if let endDate = query.filters.endDate {
            let endISO = dateFormatter.string(from: endDate)
            whereConditions.append("f.createdAt <= ?")
            bindValues.append(endISO)
        }

        // App filter - need to join segment table
        let needsSegmentJoin = query.filters.appBundleIDs != nil
        var appFilterClause = ""
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let placeholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            appFilterClause = "AND s.bundleID IN (\(placeholders))"
            bindValues.append(contentsOf: appBundleIDs)
        }

        let whereClause = whereConditions.joined(separator: " AND ")

        // OPTIMIZED: Get recent frames FIRST (limited set), THEN join with FTS
        // This avoids sorting all 200k+ FTS matches by limiting to recent 10k frames first
        let recentFramesLimit = 10000  // Only search within most recent 10k frames

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

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(database))
            Log.error("[RewindSearch] Failed to prepare all-search statement: \(error)", category: .app)
            throw DataSourceError.queryFailed(underlying: error)
        }

        // Bind parameters (order changed: date filters first, then FTS query)
        var bindIndex: Int32 = 1

        // First: bind date/app filters for the recent_frames subquery
        for value in bindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            }
            bindIndex += 1
        }

        // Then: bind FTS query
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        // Finally: bind limit and offset
        sqlite3_bind_int(statement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(query.offset))

        Log.debug("[RewindSearch] Executing SQL query...", category: .app)

        // Collect frame results (without segment metadata yet)
        var frameResults: [(docid: Int64, snippet: String, rank: Double, frameId: Int64, timestamp: Date, segmentId: Int64, videoId: Int64, frameIndex: Int)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(statement, 0)
            let snippet = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(statement, 2)
            let frameId = sqlite3_column_int64(statement, 3)
            let timestampStr = String(cString: sqlite3_column_text(statement, 4))
            let segmentId = sqlite3_column_int64(statement, 5)
            let videoId = sqlite3_column_int64(statement, 6)
            let frameIndex = Int(sqlite3_column_int(statement, 7))

            let timestamp = parseRewindTimestamp(timestampStr) ?? Date()
            frameResults.append((docid: docid, snippet: snippet, rank: rank, frameId: frameId, timestamp: timestamp, segmentId: segmentId, videoId: videoId, frameIndex: frameIndex))
        }

        guard !frameResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let totalCount = getSearchTotalCount(query: ftsQuery, db: database)
            Log.info("[RewindSearch] All search: 0 results in \(elapsed)ms", category: .app)
            return SearchResults(query: query, results: [], totalCount: totalCount, searchTimeMs: elapsed)
        }

        Log.debug("[RewindSearch] Found \(frameResults.count) frame results, fetching segment metadata...", category: .app)

        // Fetch segment metadata for just these results
        let segmentIds = Array(Set(frameResults.map { $0.segmentId }))
        Log.debug("[RewindSearch] Fetching metadata for \(segmentIds.count) unique segments", category: .app)
        let segmentMetadata = try fetchSegmentMetadata(segmentIds: segmentIds, database: database)
        Log.debug("[RewindSearch] Segment metadata fetched, building results...", category: .app)

        var results: [SearchResult] = []

        for frame in frameResults {
            let segmentMeta = segmentMetadata[frame.segmentId]
            let appBundleID = segmentMeta?.bundleID
            let windowName = segmentMeta?.windowName
            let appName = appBundleID?.components(separatedBy: ".").last

            // Use Int64 frame ID directly
            let frameID = FrameID(value: frame.frameId)

            let cleanSnippet = frame.snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: frameID,
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
                frameIndex: frame.frameIndex
            )

            results.append(result)
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        Log.info("[RewindSearch] All search: \(results.count) results in \(elapsed)ms", category: .app)

        let totalCount = getSearchTotalCount(query: ftsQuery, db: database)

        return SearchResults(
            query: query,
            results: results,
            totalCount: totalCount,
            searchTimeMs: elapsed
        )
    }

    /// Fetch segment metadata for a batch of segment IDs
    private func fetchSegmentMetadata(segmentIds: [Int64], database: OpaquePointer) throws -> [Int64: (bundleID: String?, windowName: String?)] {
        guard !segmentIds.isEmpty else { return [:] }

        let placeholders = segmentIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, bundleID, windowName FROM segment WHERE id IN (\(placeholders))"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }

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

    /// Build FTS5 query from user input
    private func buildFTSQuery(_ text: String) -> String {
        // Split into words and create FTS5 query
        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word -> String in
                // Escape special FTS5 characters
                let escaped = word
                    .replacingOccurrences(of: "\"", with: "\"\"")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: ":", with: "")
                // Add prefix wildcard for partial matching
                return "\"\(escaped)\"*"
            }

        return words.joined(separator: " ")
    }

    /// Get total count of search results (FTS-only, no joins for speed)
    private func getSearchTotalCount(query: String, db: OpaquePointer) -> Int {
        let countSQL = """
            SELECT COUNT(*)
            FROM searchRanking
            WHERE searchRanking MATCH ?
        """

        var countStmt: OpaquePointer?
        defer { sqlite3_finalize(countStmt) }

        guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK else {
            return 0
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(countStmt, 1, query, -1, SQLITE_TRANSIENT)

        if sqlite3_step(countStmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(countStmt, 0))
        }

        return 0
    }

    // MARK: - App Discovery

    /// Represents an app found in the database
    public struct AppInfo: Identifiable, Hashable, Sendable {
        public let id: String  // bundleID
        public let bundleID: String
        public let name: String  // Resolved app name

        public init(bundleID: String, name: String) {
            self.id = bundleID
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// Get all distinct apps from the database
    /// Returns apps sorted by usage frequency (most used first)
    /// Resolves actual app names from the system (including Chrome/Safari web apps)
    public func getDistinctApps() async throws -> [AppInfo] {
        guard _isConnected, let db = db else {
            throw DataSourceError.notConnected
        }

        // Query distinct bundleIDs with count for sorting by usage
        let sql = """
            SELECT bundleID, COUNT(*) as usage_count
            FROM segment
            WHERE bundleID IS NOT NULL AND bundleID != ''
            GROUP BY bundleID
            ORDER BY usage_count DESC
            LIMIT 100;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DataSourceError.queryFailed(underlying: String(cString: sqlite3_errmsg(db)))
        }

        var bundleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIDPtr = sqlite3_column_text(statement, 0) else { continue }
            let bundleID = String(cString: bundleIDPtr)
            bundleIDs.append(bundleID)
        }

        // Resolve app names on main thread (NSWorkspace requires it)
        let apps = await MainActor.run {
            bundleIDs.compactMap { bundleID -> AppInfo? in
                let name = Self.resolveAppName(bundleID: bundleID)
                return AppInfo(bundleID: bundleID, name: name)
            }
        }

        Log.debug("[RewindDataSource] Found \(apps.count) distinct apps", category: .app)
        return apps
    }

    /// Resolve the actual app name from a bundle ID
    /// Handles regular apps, Chrome apps, Safari web apps, etc.
    @MainActor
    private static func resolveAppName(bundleID: String) -> String {
        // Try to get the app URL from the bundle ID
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Read the app's Info.plist to get the display name
            let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: infoPlistURL) {
                // Try CFBundleDisplayName first (user-facing name)
                if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                    return displayName
                }
                // Fall back to CFBundleName
                if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                    return bundleName
                }
            }

            // Fall back to the file name without extension
            let fileName = appURL.deletingPathExtension().lastPathComponent
            if !fileName.isEmpty {
                return fileName
            }
        }

        // For Chrome apps that might not be in Applications, check Chrome Apps folder
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

        // Last resort: derive from bundle ID (e.g., "com.apple.Safari" -> "Safari")
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// Parse Rewind's timestamp format
    private func parseRewindTimestamp(_ str: String) -> Date? {
        // Rewind uses ISO8601 format, but sometimes without 'Z' suffix
        // Examples: "2025-12-18T23:37:42.000Z" or "2025-05-01T01:16:16.345"

        // First try with ISO8601DateFormatter (handles 'Z' suffix)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: str) {
            return date
        }
        // Try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: str) {
            return date
        }

        // Fall back to DateFormatter for timestamps without 'Z' suffix
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        if let date = dateFormatter.date(from: str) {
            return date
        }

        // Try without fractional seconds
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return dateFormatter.date(from: str)
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
