import Foundation
import SQLCipher
import Shared

/// CRUD operations for frame table (Rewind-compatible schema)
/// Uses: id, createdAt, imageFileName, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus
enum FrameQueries {

    // MARK: - Insert

    /// Insert a new frame and return the auto-generated ID
    /// Rewind-compatible: stores createdAt as INTEGER (ms since epoch), imageFileName as ISO8601 string
    static func insert(db: OpaquePointer, frame: FrameReference) throws -> Int64 {
        let sql = """
            INSERT INTO frame (
                createdAt, imageFileName, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Bind parameters (no id - let database AUTOINCREMENT)
        // createdAt: INTEGER (ms since epoch) - Rewind compatible
        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(frame.timestamp))

        // imageFileName: ISO8601 timestamp string (e.g., "2025-04-22T03:56:51.115")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let imageFileName = formatter.string(from: frame.timestamp)
        sqlite3_bind_text(statement, 2, imageFileName, -1, SQLITE_TRANSIENT)

        // segmentId: references segment.id (app session)
        sqlite3_bind_int64(statement, 3, frame.segmentID.value)

        // videoId: references video.id (150-frame video chunk) - may be NULL initially
        if frame.videoID.value > 0 {
            sqlite3_bind_int64(statement, 4, frame.videoID.value)
        } else {
            sqlite3_bind_null(statement, 4)
        }

        // videoFrameIndex: position within video (0-149)
        sqlite3_bind_int(statement, 5, Int32(frame.frameIndexInSegment))

        // isStarred: 0 or 1
        sqlite3_bind_int(statement, 6, 0)

        // encodingStatus: "pending", "success", "failed"
        sqlite3_bind_text(statement, 7, frame.encodingStatus.rawValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update Video Link

    /// Update frame's videoId and videoFrameIndex after video encoding
    static func updateVideoLink(db: OpaquePointer, frameId: Int64, videoId: Int64, videoFrameIndex: Int) throws {
        let sql = """
            UPDATE frame SET videoId = ?, videoFrameIndex = ?, encodingStatus = 'success'
            WHERE id = ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, videoId)
        sqlite3_bind_int(statement, 2, Int32(videoFrameIndex))
        sqlite3_bind_int64(statement, 3, frameId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select by ID

    static func getByID(db: OpaquePointer, id: FrameID) throws -> FrameReference? {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.id = ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, id.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseFrameRow(statement: statement!)
    }

    // MARK: - Select by Time Range

    static func getByTimeRange(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Before Timestamp (for infinite scroll - older frames)

    static func getFramesBefore(
        db: OpaquePointer,
        timestamp: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt < ?
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select After Timestamp (for infinite scroll - newer frames)

    static func getFramesAfter(
        db: OpaquePointer,
        timestamp: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt >= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Most Recent

    static func getMostRecent(db: OpaquePointer, limit: Int) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select by App

    static func getByApp(
        db: OpaquePointer,
        appBundleID: String,
        limit: Int,
        offset: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            WHERE s.bundleID = ?
            ORDER BY f.createdAt ASC
            LIMIT ? OFFSET ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, appBundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))
        sqlite3_bind_int(statement, 3, Int32(offset))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Frames Pending Video Encoding

    /// Get frames that haven't been linked to a video yet (for video chunking)
    static func getFramesPendingVideoEncoding(db: OpaquePointer, limit: Int) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.videoId IS NULL
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: FrameID) throws {
        let sql = "DELETE FROM frame WHERE id = ?;"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, id.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    static func deleteOlderThan(db: OpaquePointer, date: Date) throws -> Int {
        let sql = "DELETE FROM frame WHERE createdAt < ?;"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_changes(db))
    }

    // MARK: - Count

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM frame;"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Helpers

    /// Parse a frame row from Rewind-compatible schema
    /// Expected columns: id, createdAt, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus,
    ///                   bundleID, windowName, browserUrl (from JOIN)
    private static func parseFrameRow(statement: OpaquePointer) throws -> FrameReference {
        // Column 0: id (INTEGER)
        let frameIDValue = sqlite3_column_int64(statement, 0)
        let frameID = FrameID(value: frameIDValue)

        // Column 1: createdAt (INTEGER - ms since epoch)
        let timestampMs = sqlite3_column_int64(statement, 1)
        let timestamp = Schema.timestampToDate(timestampMs)

        // Column 2: segmentId (INTEGER - references segment.id for app session)
        let segmentIdValue = sqlite3_column_int64(statement, 2)
        let segmentID = AppSegmentID(value: segmentIdValue)

        // Column 3: videoId (INTEGER - references video.id, may be NULL)
        let videoIdValue = sqlite3_column_type(statement, 3) == SQLITE_NULL ? Int64(0) : sqlite3_column_int64(statement, 3)
        let videoID = VideoSegmentID(value: videoIdValue)

        // Column 4: videoFrameIndex (INTEGER - 0-149 position in video)
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        // Column 5: isStarred (INTEGER - 0 or 1)
        // Currently not used in FrameReference, but stored for compatibility

        // Column 6: encodingStatus (TEXT)
        let statusString = getTextOrNil(statement, 6) ?? "pending"
        let encodingStatus = EncodingStatus(rawValue: statusString) ?? .pending

        // Columns 7-9: metadata from segment JOIN (nullable)
        let appBundleID = getTextOrNil(statement, 7)
        let windowName = getTextOrNil(statement, 8)
        let browserURL = getTextOrNil(statement, 9)

        let metadata = FrameMetadata(
            appBundleID: appBundleID,
            appName: nil, // Not stored in Rewind schema
            windowName: windowName,
            browserURL: browserURL
        )

        return FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .native
        )
    }

    private static func bindTextOrNull(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func getTextOrNil(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    // MARK: - Optimized Queries with Video Info (Rewind-inspired)

    /// Get frames with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getByTimeRangeWithVideoInfo(db: OpaquePointer, from startDate: Date, to endDate: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        Log.debug("[FrameQueries] getByTimeRangeWithVideoInfo: startDate=\(startDate), endDate=\(endDate), limit=\(limit)", category: .database)

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
            let error = String(cString: sqlite3_errmsg(db))
            Log.error("[FrameQueries] SQL prepare failed: \(error)", category: .database)
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: error
            )
        }

        let startTimestamp = Schema.dateToTimestamp(startDate)
        let endTimestamp = Schema.dateToTimestamp(endDate)
        Log.debug("[FrameQueries]   Binding: startTimestamp=\(startTimestamp), endTimestamp=\(endTimestamp), limit=\(limit)", category: .database)

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        var rowCount = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            rowCount += 1
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        Log.debug("[FrameQueries] ✓ Query returned \(rowCount) rows, parsed \(results.count) frames", category: .database)
        return results
    }

    /// Get most recent frames with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getMostRecentWithVideoInfo(db: OpaquePointer, limit: Int) throws -> [FrameWithVideoInfo] {
        Log.debug("[FrameQueries] getMostRecentWithVideoInfo: limit=\(limit)", category: .database)

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName,
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
            let error = String(cString: sqlite3_errmsg(db))
            Log.error("[FrameQueries] SQL prepare failed: \(error)", category: .database)
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: error
            )
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        var rowCount = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            rowCount += 1
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        Log.debug("[FrameQueries] ✓ Query returned \(rowCount) rows, parsed \(results.count) frames", category: .database)
        return results
    }

    /// Get frames before timestamp with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getBeforeWithVideoInfo(db: OpaquePointer, timestamp: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName,
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
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Get frames after timestamp with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getAfterWithVideoInfo(db: OpaquePointer, timestamp: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName,
                   v.path, v.frameRate
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt >= ?
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
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Parse a row from a query that JOINs frame with segment and video tables
    /// Columns: f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
    ///          s.bundleID, s.windowName, v.path, v.frameRate
    private static func parseFrameWithVideoInfoRow(statement: OpaquePointer) throws -> FrameWithVideoInfo {
        // Parse frame data
        let id = FrameID(value: sqlite3_column_int64(statement, 0))
        let timestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 1))
        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let frameIndexInSegment = Int(sqlite3_column_int(statement, 4))

        Log.debug("[FrameQueries] Parsing frame: id=\(id.value), timestamp=\(timestamp), segmentID=\(segmentID.value), videoID=\(videoID.value), frameIndex=\(frameIndexInSegment)", category: .database)

        let encodingStatusText = getTextOrNil(statement, 5) ?? "pending"
        let encodingStatus = EncodingStatus(rawValue: encodingStatusText) ?? .pending
        Log.debug("[FrameQueries]   encodingStatus=\(encodingStatus)", category: .database)

        // Parse metadata from segment (columns 6-7: s.bundleID, s.windowName)
        let appBundleID = getTextOrNil(statement, 6)
        let windowName = getTextOrNil(statement, 7)
        Log.debug("[FrameQueries]   metadata: bundleID=\(appBundleID ?? "nil"), windowName=\(windowName ?? "nil")", category: .database)

        let metadata = FrameMetadata(
            appBundleID: appBundleID,
            appName: nil,  // App name not stored in segment table
            windowName: windowName,
            browserURL: nil,  // Browser URL not stored in simple segment table
            displayID: 0  // Display ID not stored in segment table
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: frameIndexInSegment,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .native
        )

        // Parse video info (columns 8-9: v.path, v.frameRate)
        var videoInfo: FrameVideoInfo? = nil
        let videoPath = getTextOrNil(statement, 8)
        Log.debug("[FrameQueries]   videoPath=\(videoPath ?? "nil"), videoID.value=\(videoID.value)", category: .database)

        if let videoPath = videoPath,
           videoID.value > 0 {
            let frameRate = sqlite3_column_double(statement, 9)

            // Convert relative path to full path (must use expandedStorageRoot to resolve ~)
            let storageRoot = AppPaths.expandedStorageRoot
            let fullPath = (storageRoot as NSString).appendingPathComponent(videoPath)

            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: frameIndexInSegment,
                frameRate: frameRate
            )
            Log.debug("[FrameQueries]   ✓ Created videoInfo: path=\(fullPath), frameIndex=\(frameIndexInSegment), frameRate=\(frameRate)", category: .database)
        } else {
            Log.warning("[FrameQueries]   ⚠️ videoInfo is nil (videoPath=\(videoPath ?? "nil"), videoID=\(videoID.value))", category: .database)
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo)
    }
}
