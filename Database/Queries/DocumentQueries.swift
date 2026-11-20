import Foundation
import SQLCipher
import Shared

/// CRUD operations for indexed documents stored in FTS/doc-segment tables
enum DocumentQueries {
    private struct EncodedOtherText: Codable {
        let appName: String?
        let browserURL: String?
    }

    // MARK: - Insert

    static func insert(db: OpaquePointer, document: IndexedDocument) throws -> Int64 {
        let lookupSQL = "SELECT segmentId FROM frame WHERE id = ? LIMIT 1;"
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, lookupSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: lookupSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, document.frameID.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(
                query: lookupSQL,
                underlying: "Missing frame for indexed document \(document.frameID.value)"
            )
        }

        let segmentID = sqlite3_column_int64(statement, 0)
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        let existingDocidSQL = """
            SELECT docid
            FROM doc_segment
            WHERE frameId = ?
            LIMIT 1;
            """
        guard sqlite3_prepare_v2(db, existingDocidSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: existingDocidSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, document.frameID.value)
        if sqlite3_step(statement) == SQLITE_ROW {
            throw DatabaseError.queryFailed(
                query: existingDocidSQL,
                underlying: "UNIQUE constraint failed: doc_segment.frameId"
            )
        }

        return try FTSQueries.indexFrame(
            db: db,
            mainText: document.content,
            chromeText: encodeOtherText(appName: document.appName, browserURL: document.browserURL),
            windowTitle: document.windowName,
            segmentId: segmentID,
            frameId: document.frameID.value
        )
    }

    // MARK: - Update

    static func update(db: OpaquePointer, id: Int64, content: String) throws {
        let sql = """
            UPDATE searchRanking
            SET text = ?
            WHERE rowid = ?;
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
        let deleteDocSegmentSQL = "DELETE FROM doc_segment WHERE docid = ?;"
        let deleteSearchSQL = "DELETE FROM searchRanking WHERE rowid = ?;"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, deleteDocSegmentSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: deleteDocSegmentSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: deleteDocSegmentSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        guard sqlite3_prepare_v2(db, deleteSearchSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: deleteSearchSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: deleteSearchSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select by Frame ID

    static func getByFrameID(db: OpaquePointer, frameID: FrameID) throws -> IndexedDocument? {
        let sql = """
            SELECT sr.rowid, ds.frameId, sr.text, sr.otherText, sr.title, f.createdAt, s.browserUrl
            FROM (
                SELECT frameId, MAX(docid) AS docid
                FROM doc_segment
                WHERE frameId IS NOT NULL
                GROUP BY frameId
            ) ds
            JOIN frame f ON f.id = ds.frameId
            JOIN searchRanking sr ON sr.rowid = ds.docid
            LEFT JOIN segment s ON s.id = f.segmentId
            WHERE ds.frameId = ?
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

        sqlite3_bind_int64(statement, 1, frameID.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseDocumentRow(statement: statement!)
    }

    // MARK: - Count

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = """
            SELECT COUNT(*)
            FROM (
                SELECT frameId, MAX(docid) AS docid
                FROM doc_segment
                WHERE frameId IS NOT NULL
                GROUP BY frameId
            ) ds
            JOIN frame f ON f.id = ds.frameId;
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
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Helpers

    private static func parseDocumentRow(statement: OpaquePointer) throws -> IndexedDocument {
        // Column 0: id
        let id = sqlite3_column_int64(statement, 0)

        // Column 1: frame_id
        let frameID = FrameID(value: sqlite3_column_int64(statement, 1))

        // Column 2: content
        guard let contentText = sqlite3_column_text(statement, 2) else {
            throw DatabaseError.queryFailed(query: "parseDocumentRow", underlying: "Missing content")
        }
        let content = String(cString: contentText)

        // Columns 3-4: stored metadata and window title
        let (appName, encodedBrowserURL) = decodeOtherText(getTextOrNil(statement, 3))
        let windowName = getTextOrNil(statement, 4)
        let browserURL = encodedBrowserURL ?? getTextOrNil(statement, 6)

        // Column 5: timestamp
        let timestampMs = sqlite3_column_int64(statement, 5)
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

    private static func encodeOtherText(appName: String?, browserURL: String?) -> String? {
        guard appName != nil || browserURL != nil else {
            return nil
        }

        let payload = EncodedOtherText(appName: appName, browserURL: browserURL)
        guard let data = try? JSONEncoder().encode(payload) else {
            return appName ?? browserURL
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeOtherText(_ rawValue: String?) -> (appName: String?, browserURL: String?) {
        guard let rawValue, !rawValue.isEmpty else {
            return (nil, nil)
        }

        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EncodedOtherText.self, from: data) {
            return (decoded.appName, decoded.browserURL)
        }

        return (rawValue, nil)
    }
}
