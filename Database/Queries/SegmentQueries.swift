import Foundation
import SQLCipher
import Shared

/// CRUD operations for video table (Rewind-compatible)
/// Handles video segment metadata for 150-frame video chunks
enum SegmentQueries {

    // MARK: - Insert

    /// Insert a new video segment and return the auto-generated ID
    static func insert(db: OpaquePointer, segment: VideoSegment) throws -> Int64 {
        // Note: path field in Rewind is just the relative path (e.g., "202505/31/d0tva3el9vhg5fjg178g")
        // We use relativePath for the same purpose
        let sql = """
            INSERT INTO video (
                height, width, path, fileSize, frameRate, processingState
            ) VALUES (?, ?, ?, ?, ?, ?);
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
        sqlite3_bind_int(statement, 1, Int32(segment.height))
        sqlite3_bind_int(statement, 2, Int32(segment.width))
        sqlite3_bind_text(statement, 3, segment.relativePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, segment.fileSizeBytes)
        // Frame rate: Retrace uses 30 FPS like Rewind
        sqlite3_bind_double(statement, 5, 30.0)
        // processingState: 0 = completed (like Rewind)
        sqlite3_bind_int(statement, 6, 0)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Select by ID

    static func getByID(db: OpaquePointer, id: VideoSegmentID) throws -> VideoSegment? {
        let sql = """
            SELECT id, height, width, path, fileSize, frameRate
            FROM video
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

        sqlite3_bind_int64(statement, 1, id.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseVideoRow(statement: statement!)
    }

    // MARK: - Select by Timestamp

    /// Find video containing a frame at the given timestamp
    static func getByTimestamp(db: OpaquePointer, timestamp: Date) throws -> VideoSegment? {
        // Query through frames to find the video
        let sql = """
            SELECT DISTINCT v.id, v.height, v.width, v.path, v.fileSize, v.frameRate
            FROM video v
            INNER JOIN frame f ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
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

        let timestampMs = Schema.dateToTimestamp(timestamp)
        sqlite3_bind_int64(statement, 1, timestampMs)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseVideoRow(statement: statement!)
    }

    // MARK: - Select by Time Range

    /// Get all videos that have frames within the time range
    static func getByTimeRange(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [VideoSegment] {
        let sql = """
            SELECT DISTINCT v.id, v.height, v.width, v.path, v.fileSize, v.frameRate
            FROM video v
            INNER JOIN frame f ON f.videoId = v.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY v.id ASC;
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

        var segments: [VideoSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let segment = try parseVideoRow(statement: statement!)
            segments.append(segment)
        }

        return segments
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: VideoSegmentID) throws {
        let sql = "DELETE FROM video WHERE id = ?;"

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

    // MARK: - Statistics

    static func getTotalStorageBytes(db: OpaquePointer) throws -> Int64 {
        let sql = "SELECT COALESCE(SUM(fileSize), 0) FROM video;"

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

        return sqlite3_column_int64(statement, 0)
    }

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM video;"

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

    /// Parse a video row from the video table
    /// Expected columns: id, height, width, path, fileSize, frameRate
    private static func parseVideoRow(statement: OpaquePointer) throws -> VideoSegment {
        // Column 0: id (INTEGER)
        let videoId = sqlite3_column_int64(statement, 0)
        let id = VideoSegmentID(value: videoId)

        // Column 1: height
        let height = Int(sqlite3_column_int(statement, 1))

        // Column 2: width
        let width = Int(sqlite3_column_int(statement, 2))

        // Column 3: path (relative path like "202505/31/d0tva3el9vhg5fjg178g")
        guard let pathText = sqlite3_column_text(statement, 3) else {
            throw DatabaseError.queryFailed(query: "parseVideoRow", underlying: "Missing path")
        }
        let relativePath = String(cString: pathText)

        // Column 4: fileSize (nullable)
        let fileSizeBytes = sqlite3_column_int64(statement, 4)

        // Column 5: frameRate
        let frameRate = sqlite3_column_double(statement, 5)

        // Note: The video table doesn't have startTime/endTime/frameCount
        // Those need to be queried from the frames table if needed
        // For now, use placeholder values (will be computed from frames when needed)
        let startTime = Date(timeIntervalSince1970: 0)
        let endTime = Date(timeIntervalSince1970: 0)
        let frameCount = 150 // Standard 150 frames per video (5 seconds @ 30 FPS)

        return VideoSegment(
            id: id,
            startTime: startTime,
            endTime: endTime,
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: relativePath,
            width: width,
            height: height,
            source: .native  // Retrace creates native videos
        )
    }
}
