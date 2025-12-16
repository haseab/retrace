import Foundation
import SQLite3
import Shared

/// CRUD operations for segments table
enum SegmentQueries {

    // MARK: - Insert

    static func insert(db: OpaquePointer, segment: VideoSegment) throws {
        let sql = """
            INSERT INTO segments (
                id, start_time, end_time, frame_count, file_size_bytes, relative_path, width, height, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
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

        // Bind parameters
        sqlite3_bind_text(statement, 1, segment.id.stringValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(segment.startTime))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(segment.endTime))
        sqlite3_bind_int(statement, 4, Int32(segment.frameCount))
        sqlite3_bind_int64(statement, 5, segment.fileSizeBytes)
        sqlite3_bind_text(statement, 6, segment.relativePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 7, Int32(segment.width))
        sqlite3_bind_int(statement, 8, Int32(segment.height))
        sqlite3_bind_text(statement, 9, segment.source.rawValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select by ID

    static func getByID(db: OpaquePointer, id: SegmentID) throws -> VideoSegment? {
        let sql = """
            SELECT id, start_time, end_time, frame_count, file_size_bytes, relative_path, width, height, source
            FROM segments
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

        sqlite3_bind_text(statement, 1, id.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegmentRow(statement: statement!)
    }

    // MARK: - Select by Timestamp

    static func getByTimestamp(db: OpaquePointer, timestamp: Date) throws -> VideoSegment? {
        let sql = """
            SELECT id, start_time, end_time, frame_count, file_size_bytes, relative_path, width, height, source
            FROM segments
            WHERE start_time <= ? AND end_time >= ?
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
        sqlite3_bind_int64(statement, 2, timestampMs)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegmentRow(statement: statement!)
    }

    // MARK: - Select by Time Range

    static func getByTimeRange(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [VideoSegment] {
        let sql = """
            SELECT id, start_time, end_time, frame_count, file_size_bytes, relative_path, width, height, source
            FROM segments
            WHERE start_time <= ? AND end_time >= ?
            ORDER BY start_time ASC;
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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(startDate))

        var segments: [VideoSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let segment = try parseSegmentRow(statement: statement!)
            segments.append(segment)
        }

        return segments
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: SegmentID) throws {
        let sql = "DELETE FROM segments WHERE id = ?;"

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

        sqlite3_bind_text(statement, 1, id.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Statistics

    static func getTotalStorageBytes(db: OpaquePointer) throws -> Int64 {
        let sql = "SELECT COALESCE(SUM(file_size_bytes), 0) FROM segments;"

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
        let sql = "SELECT COUNT(*) FROM segments;"

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

    private static func parseSegmentRow(statement: OpaquePointer) throws -> VideoSegment {
        // Column 0: id
        guard let idString = sqlite3_column_text(statement, 0) else {
            throw DatabaseError.queryFailed(query: "parseSegmentRow", underlying: "Missing segment ID")
        }
        guard let uuid = UUID(uuidString: String(cString: idString)) else {
            throw DatabaseError.queryFailed(query: "parseSegmentRow", underlying: "Invalid segment ID")
        }
        let id = SegmentID(value: uuid)

        // Column 1: start_time
        let startTimeMs = sqlite3_column_int64(statement, 1)
        let startTime = Schema.timestampToDate(startTimeMs)

        // Column 2: end_time
        let endTimeMs = sqlite3_column_int64(statement, 2)
        let endTime = Schema.timestampToDate(endTimeMs)

        // Column 3: frame_count
        let frameCount = Int(sqlite3_column_int(statement, 3))

        // Column 4: file_size_bytes
        let fileSizeBytes = sqlite3_column_int64(statement, 4)

        // Column 5: relative_path
        guard let pathText = sqlite3_column_text(statement, 5) else {
            throw DatabaseError.queryFailed(query: "parseSegmentRow", underlying: "Missing relative path")
        }
        let relativePath = String(cString: pathText)

        // Column 6: width
        let width = Int(sqlite3_column_int(statement, 6))

        // Column 7: height
        let height = Int(sqlite3_column_int(statement, 7))

        // Column 8: source
        let sourceString = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? "native"
        let source = FrameSource(rawValue: sourceString) ?? .native

        return VideoSegment(
            id: id,
            startTime: startTime,
            endTime: endTime,
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: relativePath,
            width: width,
            height: height,
            source: source
        )
    }
}
