import CoreGraphics
import Foundation
import SQLCipher
import Shared

/// Reads and writes a frame's window map (the `frame_window` table, added in V20).
enum FrameWindowQueries {

    /// Replace the window map stored for `frameId`.
    static func replace(db: OpaquePointer, frameId: Int64, windows: [CapturedWindow]) throws {
        try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try delete(db: db, frameId: frameId)
            if !windows.isEmpty {
                try insert(db: db, frameId: frameId, windows: windows)
            }
            try exec(db: db, sql: "COMMIT;")
        } catch {
            try? exec(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    /// Window map for `frameId`, front to back. Empty when none was recorded.
    static func fetch(db: OpaquePointer, frameId: Int64) throws -> [CapturedWindow] {
        let sql = """
            SELECT windowId, zOrder, bundleID, appName, title, x, y, width, height, layer, isFocused
            FROM frame_window
            WHERE frameId = ?
            ORDER BY zOrder ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(db: db, sql: sql, statement: &statement)
        sqlite3_bind_int64(statement, 1, frameId)

        var windows: [CapturedWindow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            windows.append(
                CapturedWindow(
                    windowID: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 0)),
                    zOrder: Int(sqlite3_column_int64(statement, 1)),
                    bundleID: text(statement!, 2),
                    appName: text(statement!, 3),
                    title: text(statement!, 4),
                    bounds: CGRect(
                        x: sqlite3_column_double(statement, 5),
                        y: sqlite3_column_double(statement, 6),
                        width: sqlite3_column_double(statement, 7),
                        height: sqlite3_column_double(statement, 8)
                    ),
                    layer: Int(sqlite3_column_int64(statement, 9)),
                    isFocused: sqlite3_column_int64(statement, 10) != 0
                )
            )
        }
        return windows
    }

    // MARK: - Private

    private static func delete(db: OpaquePointer, frameId: Int64) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "DELETE FROM frame_window WHERE frameId = ?;"
        try prepare(db: db, sql: sql, statement: &statement)
        sqlite3_bind_int64(statement, 1, frameId)
        try step(db: db, sql: sql, statement: statement)
    }

    private static func insert(db: OpaquePointer, frameId: Int64, windows: [CapturedWindow]) throws {
        let sql = """
            INSERT INTO frame_window
                (frameId, zOrder, windowId, bundleID, appName, title, x, y, width, height, layer, isFocused)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(db: db, sql: sql, statement: &statement)

        for window in windows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, frameId)
            sqlite3_bind_int64(statement, 2, Int64(window.zOrder))
            sqlite3_bind_int64(statement, 3, Int64(window.windowID))
            bind(statement, 4, window.bundleID)
            bind(statement, 5, window.appName)
            bind(statement, 6, window.title)
            sqlite3_bind_double(statement, 7, Double(window.bounds.origin.x))
            sqlite3_bind_double(statement, 8, Double(window.bounds.origin.y))
            sqlite3_bind_double(statement, 9, Double(window.bounds.width))
            sqlite3_bind_double(statement, 10, Double(window.bounds.height))
            sqlite3_bind_int64(statement, 11, Int64(window.layer))
            sqlite3_bind_int64(statement, 12, window.isFocused ? 1 : 0)
            try step(db: db, sql: sql, statement: statement)
        }
    }

    private static func prepare(db: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func step(db: OpaquePointer, sql: String, statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func exec(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}
