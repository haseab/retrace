import Foundation
import SQLCipher
import Shared

/// CRUD operations for video table (Rewind-compatible)
/// Handles video segment metadata for 150-frame video chunks
enum SegmentQueries {

    // MARK: - Insert

    /// Insert a new video segment and return the auto-generated ID
    static func insert(db: OpaquePointer, segment: VideoSegment, displayID: UInt32 = 0) throws -> Int64 {
        // Note: path field in Rewind is just the relative path (e.g., "202505/31/d0tva3el9vhg5fjg178g")
        // We use relativePath for the same purpose
        let sql = """
            INSERT INTO video (
                height, width, path, fileSize, frameRate, processingState, displayID
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
        sqlite3_bind_int(statement, 1, Int32(segment.height))
        sqlite3_bind_int(statement, 2, Int32(segment.width))
        sqlite3_bind_text(statement, 3, segment.relativePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, segment.fileSizeBytes)
        // Frame rate: Retrace uses 30 FPS like Rewind
        sqlite3_bind_double(statement, 5, 30.0)
        // processingState: 1 = in progress (still being written to), 0 = completed
        sqlite3_bind_int(statement, 6, 1)
        // displayID: which physical display this video is from
        sqlite3_bind_int(statement, 7, Int32(displayID))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    /// Update video segment metadata (fileSize, frameCount, width, height)
    /// Called periodically during recording to keep DB in sync with file
    static func update(db: OpaquePointer, id: Int64, width: Int, height: Int, fileSize: Int64, frameCount: Int? = nil) throws {
        let sql: String
        if frameCount != nil {
            sql = """
                UPDATE video SET width = ?, height = ?, fileSize = ?, frameCount = ?
                WHERE id = ?;
                """
        } else {
            sql = """
                UPDATE video SET width = ?, height = ?, fileSize = ?
                WHERE id = ?;
                """
        }

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

        sqlite3_bind_int(statement, 1, Int32(width))
        sqlite3_bind_int(statement, 2, Int32(height))
        sqlite3_bind_int64(statement, 3, fileSize)

        if let frameCount = frameCount {
            sqlite3_bind_int(statement, 4, Int32(frameCount))
            sqlite3_bind_int64(statement, 5, id)
        } else {
            sqlite3_bind_int64(statement, 4, id)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Mark a video as finalized (complete, no more frames will be added)
    /// Sets processingState = 0 (completed), updates uploadedAt timestamp, fileSize, and frameCount
    static func markFinalized(db: OpaquePointer, id: Int64, frameCount: Int, fileSize: Int64) throws {
        let sql = """
            UPDATE video SET processingState = 0, frameCount = ?, fileSize = ?, uploadedAt = ?
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

        let currentTimestamp = Schema.currentTimestamp()
        sqlite3_bind_int(statement, 1, Int32(frameCount))
        sqlite3_bind_int64(statement, 2, fileSize)
        sqlite3_bind_int64(statement, 3, currentTimestamp)
        sqlite3_bind_int64(statement, 4, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Finalize all orphaned videos (processingState=1) that don't have active WAL sessions
    /// This cleans up videos left unfinalised due to dev restarts or crashes
    /// Returns the number of videos finalized
    static func finalizeOrphanedVideos(db: OpaquePointer, activeVideoIDs: Set<Int64>) throws -> Int {
        // If there are active video IDs, exclude them from finalization
        let sql: String
        if activeVideoIDs.isEmpty {
            sql = """
                UPDATE video SET processingState = 0, uploadedAt = ?
                WHERE processingState = 1;
                """
        } else {
            let placeholders = activeVideoIDs.map { _ in "?" }.joined(separator: ", ")
            sql = """
                UPDATE video SET processingState = 0, uploadedAt = ?
                WHERE processingState = 1 AND id NOT IN (\(placeholders));
                """
        }

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

        let currentTimestamp = Schema.currentTimestamp()
        sqlite3_bind_int64(statement, 1, currentTimestamp)

        // Bind active video IDs if any
        for (index, videoID) in activeVideoIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 2), videoID)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_changes(db))
    }

    /// Get an unfinalised video matching the given resolution
    /// Returns nil if no unfinalised video exists for this resolution
    /// Used to resume writing to an existing video when a frame with matching resolution comes in
    static func getUnfinalisedByResolution(db: OpaquePointer, width: Int, height: Int) throws -> UnfinalisedVideo? {
        let sql = """
            SELECT id, path, frameCount, displayID
            FROM video
            WHERE width = ? AND height = ? AND processingState = 1
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

        sqlite3_bind_int(statement, 1, Int32(width))
        sqlite3_bind_int(statement, 2, Int32(height))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let id = sqlite3_column_int64(statement, 0)
        guard let pathText = sqlite3_column_text(statement, 1) else {
            return nil
        }
        let path = String(cString: pathText)
        let frameCount = Int(sqlite3_column_int(statement, 2))
        let displayID = UInt32(sqlite3_column_int(statement, 3))

        return UnfinalisedVideo(
            id: id,
            relativePath: path,
            frameCount: frameCount,
            width: width,
            height: height,
            displayID: displayID
        )
    }

    /// Get an unfinalised video matching the given display ID and resolution
    /// Used in multi-display mode to prevent resuming the wrong display's video
    static func getUnfinalisedByDisplayAndResolution(db: OpaquePointer, displayID: UInt32, width: Int, height: Int) throws -> UnfinalisedVideo? {
        let sql = """
            SELECT id, path, frameCount
            FROM video
            WHERE displayID = ? AND width = ? AND height = ? AND processingState = 1
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

        sqlite3_bind_int(statement, 1, Int32(displayID))
        sqlite3_bind_int(statement, 2, Int32(width))
        sqlite3_bind_int(statement, 3, Int32(height))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let id = sqlite3_column_int64(statement, 0)
        guard let pathText = sqlite3_column_text(statement, 1) else {
            return nil
        }
        let path = String(cString: pathText)
        let frameCount = Int(sqlite3_column_int(statement, 2))

        return UnfinalisedVideo(
            id: id,
            relativePath: path,
            frameCount: frameCount,
            width: width,
            height: height,
            displayID: displayID
        )
    }

    /// Get all unfinalised videos (for recovery on app startup)
    /// processingState = 1 means video is still being written to
    static func getAllUnfinalised(db: OpaquePointer) throws -> [UnfinalisedVideo] {
        let sql = """
            SELECT id, path, frameCount, width, height, displayID
            FROM video
            WHERE processingState = 1;
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

        var results: [UnfinalisedVideo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let pathText = sqlite3_column_text(statement, 1) else { continue }
            let path = String(cString: pathText)
            let frameCount = Int(sqlite3_column_int(statement, 2))
            let width = Int(sqlite3_column_int(statement, 3))
            let height = Int(sqlite3_column_int(statement, 4))
            let displayID = UInt32(sqlite3_column_int(statement, 5))

            results.append(UnfinalisedVideo(
                id: id,
                relativePath: path,
                frameCount: frameCount,
                width: width,
                height: height,
                displayID: displayID
            ))
        }

        return results
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
