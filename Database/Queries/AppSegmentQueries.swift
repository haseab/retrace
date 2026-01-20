import Foundation
import SQLite3
import Shared

// MARK: - App Segment Queries

/// SQL queries for Rewind-compatible segment table (app focus sessions)
/// Owner: DATABASE agent
enum AppSegmentQueries {

    // MARK: - Insert

    static func insert(
        db: OpaquePointer,
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int = 0
    ) throws -> Int64 {
        let sql = """
            INSERT INTO segment (
                bundleID, startDate, endDate, windowName, browserUrl, type
            ) VALUES (?, ?, ?, ?, ?, ?)
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(endDate))
        bindTextOrNull(statement, 4, windowName)
        bindTextOrNull(statement, 5, browserUrl)
        sqlite3_bind_int(statement, 6, Int32(type))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    static func updateEndDate(db: OpaquePointer, id: Int64, endDate: Date) throws {
        let sql = """
            UPDATE segment
            SET endDate = ?
            WHERE id = ?
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
        sqlite3_bind_int64(statement, 2, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Update browserURL if currently null
    /// Used to backfill URLs extracted from OCR after capture
    static func updateBrowserURL(db: OpaquePointer, id: Int64, browserURL: String) throws {
        let sql = """
            UPDATE segment
            SET browserUrl = ?
            WHERE id = ? AND browserUrl IS NULL
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

        sqlite3_bind_text(statement, 1, browserURL, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select

    static func getByID(db: OpaquePointer, id: Int64) throws -> Segment? {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE id = ?
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

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegment(statement: statement!)
    }

    static func getByTimeRange(db: OpaquePointer, from startDate: Date, to endDate: Date) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE startDate <= ? AND endDate >= ?
            ORDER BY startDate DESC
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

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    static func getMostRecent(db: OpaquePointer, limit: Int = 1) throws -> Segment? {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            ORDER BY startDate DESC
            LIMIT ?
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

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegment(statement: statement!)
    }

    static func getByBundleID(db: OpaquePointer, bundleID: String, limit: Int) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE bundleID = ?
            ORDER BY startDate DESC
            LIMIT ?
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    static func getByBundleIDAndTimeRange(
        db: OpaquePointer,
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE bundleID = ?
              AND startDate <= ?
              AND endDate >= ?
            ORDER BY startDate DESC
            LIMIT ? OFFSET ?
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int(statement, 4, Int32(limit))
        sqlite3_bind_int(statement, 5, Int32(offset))

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    // MARK: - Statistics

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM segment;"

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

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: Int64) throws {
        let sql = "DELETE FROM segment WHERE id = ?"

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

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Helper

    private static func parseSegment(statement: OpaquePointer) throws -> Segment {
        let id = sqlite3_column_int64(statement, 0)
        let bundleID = String(cString: sqlite3_column_text(statement, 1))
        let startDate = Schema.timestampToDate(sqlite3_column_int64(statement, 2))
        let endDate = Schema.timestampToDate(sqlite3_column_int64(statement, 3))
        let windowName = sqlite3_column_type(statement, 4) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 4))
            : nil
        let browserUrl = sqlite3_column_type(statement, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 5))
            : nil
        let type = Int(sqlite3_column_int(statement, 6))

        return Segment(
            id: SegmentID(value: id),
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }
}

// MARK: - Helper

private func bindTextOrNull(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
    if let value = value {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(statement, index)
    }
}
