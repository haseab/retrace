import Foundation
import SQLCipher
import Shared

enum DisplayQueries {

    static func upsertName(db: OpaquePointer, displayID: UInt32, name: String, seenAt: Date) throws {
        let sql = """
            INSERT INTO display (displayID, name, lastSeenAt)
            VALUES (?, ?, ?)
            ON CONFLICT(displayID) DO UPDATE SET
                name = excluded.name,
                lastSeenAt = excluded.lastSeenAt;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(statement, 1, Int32(displayID))
        sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(seenAt))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    static func getNames(db: OpaquePointer, displayIDs: [UInt32]) throws -> [UInt32: String] {
        guard !displayIDs.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: displayIDs.count).joined(separator: ",")
        let sql = """
            SELECT displayID, name
            FROM display
            WHERE displayID IN (\(placeholders));
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        for (index, displayID) in displayIDs.enumerated() {
            sqlite3_bind_int(statement, Int32(index + 1), Int32(displayID))
        }

        var result: [UInt32: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UInt32(sqlite3_column_int(statement, 0))
            guard let cString = sqlite3_column_text(statement, 1) else { continue }
            result[id] = String(cString: cString)
        }

        return result
    }

    // MARK: - Display Session Operations

    /// Open a display session if no open session exists for this display.
    /// - Returns: true if a new open session row was inserted.
    static func openSegment(db: OpaquePointer, displayID: UInt32, connectedAt: Date) throws -> Bool {
        let sql = """
            INSERT INTO display_session (displayID, connectedAt, disconnectedAt)
            SELECT ?, ?, NULL
            WHERE NOT EXISTS (
                SELECT 1
                FROM display_session
                WHERE displayID = ? AND disconnectedAt IS NULL
            );
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let timestamp = Schema.dateToTimestamp(connectedAt)
        sqlite3_bind_int(statement, 1, Int32(displayID))
        sqlite3_bind_int64(statement, 2, timestamp)
        sqlite3_bind_int(statement, 3, Int32(displayID))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_changes(db) > 0
    }

    /// Close an open display session for a display ID.
    /// - Returns: true if at least one open session was closed.
    static func closeOpenSegment(db: OpaquePointer, displayID: UInt32, disconnectedAt: Date) throws -> Bool {
        let sql = """
            UPDATE display_session
            SET disconnectedAt = ?
            WHERE displayID = ? AND disconnectedAt IS NULL;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(disconnectedAt))
        sqlite3_bind_int(statement, 2, Int32(displayID))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_changes(db) > 0
    }

    /// Close all open display sessions.
    /// - Returns: number of rows updated.
    static func closeAllOpenSegments(db: OpaquePointer, disconnectedAt: Date) throws -> Int {
        let sql = """
            UPDATE display_session
            SET disconnectedAt = ?
            WHERE disconnectedAt IS NULL;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(disconnectedAt))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Get displays that are connected at a specific timestamp.
    static func getConnectedDisplayIDs(db: OpaquePointer, at timestamp: Date) throws -> [UInt32] {
        let sql = """
            SELECT DISTINCT displayID
            FROM display_session
            WHERE connectedAt <= ?
              AND (disconnectedAt IS NULL OR disconnectedAt >= ?)
            ORDER BY displayID ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let ts = Schema.dateToTimestamp(timestamp)
        sqlite3_bind_int64(statement, 1, ts)
        sqlite3_bind_int64(statement, 2, ts)

        var displayIDs: [UInt32] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            displayIDs.append(UInt32(sqlite3_column_int(statement, 0)))
        }

        return displayIDs
    }

    /// Get display IDs that currently have an open display session.
    static func getOpenDisplaySegmentIDs(db: OpaquePointer) throws -> [UInt32] {
        let sql = """
            SELECT displayID
            FROM display_session
            WHERE disconnectedAt IS NULL
            ORDER BY displayID ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var displayIDs: [UInt32] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            displayIDs.append(UInt32(sqlite3_column_int(statement, 0)))
        }

        return displayIDs
    }
}
