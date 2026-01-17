import Foundation
import SQLCipher
import Shared

/// CRUD operations for FTS5 search tables (Rewind-compatible)
/// Handles searchRanking_content and doc_segment tables
///
/// Rewind FTS Pattern:
/// 1. INSERT INTO searchRanking_content (c0, c1, c2) → get docid
/// 2. INSERT INTO doc_segment (docid, segmentId, frameId)
/// 3. FTS5 automatically indexes via external content configuration
enum FTSQueries {

    // MARK: - Insert FTS Content

    /// Insert OCR text into searchRanking_content and return the docid
    /// This is the Rewind-compatible pattern for FTS indexing
    ///
    /// - Parameters:
    ///   - db: Database connection
    ///   - mainText: Main OCR text (c0) - concatenated text from all nodes
    ///   - chromeText: UI chrome text (c1) - status bar, menu bar text (optional)
    ///   - windowTitle: Window title (c2) - from app metadata
    /// - Returns: The docid (rowid) of the inserted content
    static func insertContent(
        db: OpaquePointer,
        mainText: String,
        chromeText: String?,
        windowTitle: String?
    ) throws -> Int64 {
        let sql = """
            INSERT INTO searchRanking_content (c0, c1, c2)
            VALUES (?, ?, ?);
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
        sqlite3_bind_text(statement, 1, mainText, -1, SQLITE_TRANSIENT)
        bindTextOrNull(statement, 2, chromeText)
        bindTextOrNull(statement, 3, windowTitle)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Return the docid (last inserted rowid)
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Insert doc_segment Junction

    /// Insert junction record linking FTS document to frame and segment
    /// This enables the join: searchRanking → doc_segment → frame → node
    ///
    /// - Parameters:
    ///   - db: Database connection
    ///   - docid: The docid from insertContent()
    ///   - segmentId: The segment ID (app focus session)
    ///   - frameId: The frame ID (can be nil for audio-only segments)
    static func insertDocSegment(
        db: OpaquePointer,
        docid: Int64,
        segmentId: Int64,
        frameId: Int64?
    ) throws {
        let sql = """
            INSERT INTO doc_segment (docid, segmentId, frameId)
            VALUES (?, ?, ?);
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

        sqlite3_bind_int64(statement, 1, docid)
        sqlite3_bind_int64(statement, 2, segmentId)

        if let frameId = frameId {
            sqlite3_bind_int64(statement, 3, frameId)
        } else {
            sqlite3_bind_null(statement, 3)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Combined Insert (Convenience)

    /// Insert FTS content and doc_segment junction in one call
    /// This is the main entry point for indexing OCR text
    ///
    /// - Parameters:
    ///   - db: Database connection
    ///   - mainText: Main OCR text (concatenated from all nodes)
    ///   - chromeText: UI chrome text (optional)
    ///   - windowTitle: Window title
    ///   - segmentId: Segment ID for the app session
    ///   - frameId: Frame ID for the screenshot
    /// - Returns: The docid for reference by nodes
    static func indexFrame(
        db: OpaquePointer,
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) throws -> Int64 {
        // Step 1: Insert into searchRanking_content
        let docid = try insertContent(
            db: db,
            mainText: mainText,
            chromeText: chromeText,
            windowTitle: windowTitle
        )

        // Step 2: Insert junction record
        try insertDocSegment(
            db: db,
            docid: docid,
            segmentId: segmentId,
            frameId: frameId
        )

        return docid
    }

    // MARK: - Select

    /// Get FTS content by docid
    static func getContent(db: OpaquePointer, docid: Int64) throws -> (mainText: String, chromeText: String?, windowTitle: String?)? {
        let sql = """
            SELECT c0, c1, c2
            FROM searchRanking_content
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

        sqlite3_bind_int64(statement, 1, docid)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let mainText = getTextOrEmpty(statement!, 0)
        let chromeText = getTextOrNil(statement!, 1)
        let windowTitle = getTextOrNil(statement!, 2)

        return (mainText, chromeText, windowTitle)
    }

    /// Get docid for a frame
    static func getDocidForFrame(db: OpaquePointer, frameId: Int64) throws -> Int64? {
        let sql = """
            SELECT docid
            FROM doc_segment
            WHERE frameId = ?;
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

        sqlite3_bind_int64(statement, 1, frameId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Delete

    /// Delete FTS content and associated doc_segment records for a frame
    static func deleteForFrame(db: OpaquePointer, frameId: Int64) throws {
        // First get the docid
        guard let docid = try getDocidForFrame(db: db, frameId: frameId) else {
            return // Nothing to delete
        }

        // Delete from doc_segment
        let deleteJunctionSQL = "DELETE FROM doc_segment WHERE frameId = ?;"
        var junctionStatement: OpaquePointer?
        defer {
            sqlite3_finalize(junctionStatement)
        }

        guard sqlite3_prepare_v2(db, deleteJunctionSQL, -1, &junctionStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: deleteJunctionSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(junctionStatement, 1, frameId)

        guard sqlite3_step(junctionStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: deleteJunctionSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // Delete from searchRanking_content
        let deleteContentSQL = "DELETE FROM searchRanking_content WHERE id = ?;"
        var contentStatement: OpaquePointer?
        defer {
            sqlite3_finalize(contentStatement)
        }

        guard sqlite3_prepare_v2(db, deleteContentSQL, -1, &contentStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: deleteContentSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(contentStatement, 1, docid)

        guard sqlite3_step(contentStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: deleteContentSQL,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Statistics

    static func getContentCount(db: OpaquePointer) throws -> Int {
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

    static func getDocSegmentCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM doc_segment;"

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

    private static func getTextOrEmpty(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }
}
