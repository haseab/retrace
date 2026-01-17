import Foundation
import SQLCipher
import Shared

/// CRUD operations for documents table
enum DocumentQueries {

    // MARK: - Insert

    static func insert(db: OpaquePointer, document: IndexedDocument) throws -> Int64 {
        let sql = """
            INSERT INTO documents (
                frame_id, content, app_name, window_name, browser_url, timestamp
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

        // Bind parameters
        sqlite3_bind_text(statement, 1, document.frameID.stringValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, document.content, -1, SQLITE_TRANSIENT)
        bindTextOrNull(statement, 3, document.appName)
        bindTextOrNull(statement, 4, document.windowName)
        bindTextOrNull(statement, 5, document.browserURL)
        sqlite3_bind_int64(statement, 6, Schema.dateToTimestamp(document.timestamp))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Return the rowid of the inserted document
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    static func update(db: OpaquePointer, id: Int64, content: String) throws {
        let sql = "UPDATE documents SET content = ? WHERE id = ?;"

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

        sqlite3_bind_text(statement, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: Int64) throws {
        let sql = "DELETE FROM documents WHERE id = ?;"

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

    // MARK: - Select by Frame ID

    static func getByFrameID(db: OpaquePointer, frameID: FrameID) throws -> IndexedDocument? {
        let sql = """
            SELECT id, frame_id, content, app_name, window_name, browser_url, timestamp
            FROM documents
            WHERE frame_id = ?;
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

        sqlite3_bind_text(statement, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseDocumentRow(statement: statement!)
    }

    // MARK: - Count

    static func getCount(db: OpaquePointer) throws -> Int {
        // Use Rewind-compatible table name
        let sql = "SELECT COUNT(*) FROM searchRanking_content;"

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

    private static func parseDocumentRow(statement: OpaquePointer) throws -> IndexedDocument {
        // Column 0: id
        let id = sqlite3_column_int64(statement, 0)

        // Column 1: frame_id
        guard let frameIDString = sqlite3_column_text(statement, 1) else {
            throw DatabaseError.queryFailed(query: "parseDocumentRow", underlying: "Missing frame ID")
        }
        guard let frameID = FrameID(string: String(cString: frameIDString)) else {
            throw DatabaseError.queryFailed(query: "parseDocumentRow", underlying: "Invalid frame ID")
        }

        // Column 2: content
        guard let contentText = sqlite3_column_text(statement, 2) else {
            throw DatabaseError.queryFailed(query: "parseDocumentRow", underlying: "Missing content")
        }
        let content = String(cString: contentText)

        // Columns 3-5: nullable metadata
        let appName = getTextOrNil(statement, 3)
        let windowName = getTextOrNil(statement, 4)
        let browserURL = getTextOrNil(statement, 5)

        // Column 6: timestamp
        let timestampMs = sqlite3_column_int64(statement, 6)
        let timestamp = Schema.timestampToDate(timestampMs)

        return IndexedDocument(
            id: id,
            frameID: frameID,
            timestamp: timestamp,
            content: content,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL
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
}
