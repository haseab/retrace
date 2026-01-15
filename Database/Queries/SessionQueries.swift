import Foundation
import SQLCipher
import Shared

// MARK: - Session Queries

/// SQL queries for app_sessions table
/// Owner: DATABASE agent
enum SessionQueries {

    // MARK: - Insert

    static func insert(db: OpaquePointer, session: AppSession) throws {
        let sql = """
            INSERT INTO app_sessions (
                id, app_bundle_id, app_name, window_name, browser_url,
                display_id, start_time, end_time
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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

        sqlite3_bind_text(statement, 1, session.id.stringValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, session.appBundleID, -1, SQLITE_TRANSIENT)
        bindTextOrNull(statement, 3, session.appName)
        bindTextOrNull(statement, 4, session.windowName)
        bindTextOrNull(statement, 5, session.browserURL)
        if let displayID = session.displayID {
            sqlite3_bind_int64(statement, 6, Int64(displayID))
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int64(statement, 7, Schema.dateToTimestamp(session.startTime))
        if let endTime = session.endTime {
            sqlite3_bind_int64(statement, 8, Schema.dateToTimestamp(endTime))
        } else {
            sqlite3_bind_null(statement, 8)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Update

    static func updateEndTime(db: OpaquePointer, id: AppSessionID, endTime: Date) throws {
        let sql = """
            UPDATE app_sessions
            SET end_time = ?
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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(endTime))
        sqlite3_bind_text(statement, 2, id.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select

    static func getByID(db: OpaquePointer, id: AppSessionID) throws -> AppSession? {
        let sql = """
            SELECT id, app_bundle_id, app_name, window_name, browser_url,
                   display_id, start_time, end_time
            FROM app_sessions
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

        sqlite3_bind_text(statement, 1, id.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSession(statement: statement!)
    }

    static func getByTimeRange(db: OpaquePointer, from startDate: Date, to endDate: Date) throws -> [AppSession] {
        let sql = """
            SELECT id, app_bundle_id, app_name, window_name, browser_url,
                   display_id, start_time, end_time
            FROM app_sessions
            WHERE start_time <= ? AND (end_time >= ? OR end_time IS NULL)
            ORDER BY start_time DESC
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

        var results: [AppSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSession(statement: statement!))
        }
        return results
    }

    static func getActive(db: OpaquePointer) throws -> AppSession? {
        let sql = """
            SELECT id, app_bundle_id, app_name, window_name, browser_url,
                   display_id, start_time, end_time
            FROM app_sessions
            WHERE end_time IS NULL
            ORDER BY start_time DESC
            LIMIT 1
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

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSession(statement: statement!)
    }

    static func getByApp(db: OpaquePointer, appBundleID: String, limit: Int) throws -> [AppSession] {
        let sql = """
            SELECT id, app_bundle_id, app_name, window_name, browser_url,
                   display_id, start_time, end_time
            FROM app_sessions
            WHERE app_bundle_id = ?
            ORDER BY start_time DESC
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

        sqlite3_bind_text(statement, 1, appBundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [AppSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSession(statement: statement!))
        }
        return results
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: AppSessionID) throws {
        let sql = "DELETE FROM app_sessions WHERE id = ?"

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

    // MARK: - Helper

    private static func parseSession(statement: OpaquePointer) throws -> AppSession {
        let id = AppSessionID(string: String(cString: sqlite3_column_text(statement, 0)))!
        let appBundleID = String(cString: sqlite3_column_text(statement, 1))
        let appName = sqlite3_column_type(statement, 2) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 2))
            : nil
        let windowName = sqlite3_column_type(statement, 3) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 3))
            : nil
        let browserURL = sqlite3_column_type(statement, 4) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 4))
            : nil
        let displayID = sqlite3_column_type(statement, 5) != SQLITE_NULL
            ? UInt32(sqlite3_column_int64(statement, 5))
            : nil
        let startTime = Schema.timestampToDate(sqlite3_column_int64(statement, 6))
        let endTime = sqlite3_column_type(statement, 7) != SQLITE_NULL
            ? Schema.timestampToDate(sqlite3_column_int64(statement, 7))
            : nil

        return AppSession(
            id: id,
            appBundleID: appBundleID,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL,
            displayID: displayID,
            startTime: startTime,
            endTime: endTime
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
