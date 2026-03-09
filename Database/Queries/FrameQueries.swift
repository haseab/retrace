import Foundation
import SQLCipher
import Shared

/// CRUD operations for frame table (Rewind-compatible schema)
/// Uses: id, createdAt, imageFileName, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus
enum FrameQueries {
    // MARK: - Insert

    /// Insert a new frame and return the auto-generated ID
    /// Rewind-compatible: stores createdAt as INTEGER (ms since epoch), imageFileName as ISO8601 string
    /// processingStatus = 4 means "not yet readable from video file" - will be updated to 0 when confirmed in video
    static func insert(db: OpaquePointer, frame: FrameReference) throws -> Int64 {
        let sql = """
            INSERT INTO frame (
                createdAt, imageFileName, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus, redactionReason, processingStatus
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 4);
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
        // createdAt: INTEGER (ms since epoch) - Rewind compatible
        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(frame.timestamp))

        // imageFileName: ISO8601 timestamp string (e.g., "2025-04-22T03:56:51.115")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let imageFileName = formatter.string(from: frame.timestamp)
        sqlite3_bind_text(statement, 2, imageFileName, -1, SQLITE_TRANSIENT)

        // segmentId: references segment.id (app session)
        sqlite3_bind_int64(statement, 3, frame.segmentID.value)

        // videoId: references video.id (150-frame video chunk) - may be NULL initially
        if frame.videoID.value > 0 {
            sqlite3_bind_int64(statement, 4, frame.videoID.value)
        } else {
            sqlite3_bind_null(statement, 4)
        }

        // videoFrameIndex: position within video (0-149)
        sqlite3_bind_int(statement, 5, Int32(frame.frameIndexInSegment))

        // isStarred: 0 or 1
        sqlite3_bind_int(statement, 6, 0)

        // encodingStatus: "pending", "success", "failed"
        sqlite3_bind_text(statement, 7, frame.encodingStatus.rawValue, -1, SQLITE_TRANSIENT)

        // redactionReason: nullable, set when frame pixels were intentionally redacted
        bindTextOrNull(statement, 8, frame.metadata.redactionReason)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update Video Link

    /// Update frame's videoId and videoFrameIndex after video encoding
    static func updateVideoLink(db: OpaquePointer, frameId: Int64, videoId: Int64, videoFrameIndex: Int) throws {
        let sql = """
            UPDATE frame SET videoId = ?, videoFrameIndex = ?, encodingStatus = 'success'
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

        sqlite3_bind_int64(statement, 1, videoId)
        sqlite3_bind_int(statement, 2, Int32(videoFrameIndex))
        sqlite3_bind_int64(statement, 3, frameId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Persist optional metadata JSON payload for a frame.
    static func updateMetadata(db: OpaquePointer, frameId: Int64, metadataJSON: String?) throws {
        let sql = """
            UPDATE frame
            SET metadata = ?
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

        bindTextOrNull(statement, 1, metadataJSON)
        sqlite3_bind_int64(statement, 2, frameId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Get metadata JSON payload for a frame.
    static func getMetadata(db: OpaquePointer, frameId: Int64) throws -> String? {
        let sql = """
            SELECT metadata
            FROM frame
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

        sqlite3_bind_int64(statement, 1, frameId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return getTextOrNil(statement!, 0)
    }

    /// Replace resolved in-page URL rows/context for a frame.
    static func replaceInPageURLData(
        db: OpaquePointer,
        frameId: Int64,
        state: FrameInPageURLState?,
        rows: [FrameInPageURLRow]
    ) throws {
        try ensureInPageURLSchema(db: db)
        try beginTransaction(db: db)
        do {
            try deleteInPageURLRows(db: db, frameId: frameId)
            try updateInPageURLState(db: db, frameId: frameId, state: state)

            if !rows.isEmpty {
                try insertInPageURLRows(db: db, frameId: frameId, rows: rows)
            }

            try commitTransaction(db: db)
        } catch {
            try? rollbackTransaction(db: db)
            throw error
        }
    }

    /// Get resolved in-page URL rows for a frame.
    static func getInPageURLRows(db: OpaquePointer, frameId: Int64) throws -> [FrameInPageURLRow] {
        try ensureInPageURLSchema(db: db)
        let sql = """
            SELECT r.ord, t.url, r.nid
            FROM frame_in_page_url r
            INNER JOIN in_page_url_text t
                ON t.id = r.urlId
            WHERE r.frameId = ?
            ORDER BY r.ord ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameId)
        var rows: [FrameInPageURLRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                FrameInPageURLRow(
                    order: Int(sqlite3_column_int64(statement, 0)),
                    url: getTextOrNil(statement!, 1) ?? "",
                    nodeID: Int(sqlite3_column_int64(statement, 2))
                )
            )
        }

        return rows
    }

    static func getInPageURLState(db: OpaquePointer, frameId: Int64) throws -> FrameInPageURLState? {
        try ensureInPageURLSchema(db: db)
        let sql = """
            SELECT mousePosition, scrollPosition, videoCurrentTime
            FROM frame
            WHERE id = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

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

        let mousePosition = decodePoint(getTextOrNil(statement!, 0))
        let scrollPosition = decodePoint(getTextOrNil(statement!, 1))
        let videoCurrentTime = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 2)

        guard mousePosition != nil || scrollPosition != nil || videoCurrentTime != nil else {
            return nil
        }

        return FrameInPageURLState(
            mouseX: mousePosition?.x,
            mouseY: mousePosition?.y,
            scrollX: scrollPosition?.x,
            scrollY: scrollPosition?.y,
            videoCurrentTime: videoCurrentTime
        )
    }
    private static func ensureInPageURLFrameColumns(db: OpaquePointer) throws {
        if !(try hasColumn(db: db, table: "frame", column: "mousePosition")) {
            try executeSQL(db: db, sql: "ALTER TABLE frame ADD COLUMN mousePosition TEXT;")
        }
        if !(try hasColumn(db: db, table: "frame", column: "scrollPosition")) {
            try executeSQL(db: db, sql: "ALTER TABLE frame ADD COLUMN scrollPosition TEXT;")
        }
        if !(try hasColumn(db: db, table: "frame", column: "videoCurrentTime")) {
            try executeSQL(db: db, sql: "ALTER TABLE frame ADD COLUMN videoCurrentTime REAL;")
        }
    }

    static func ensureInPageURLSchema(db: OpaquePointer) throws {
        try ensureInPageURLFrameColumns(db: db)

        let usesLegacyInlineRows = try usesLegacyInPageURLRowStorage(db: db)
        let usesSharedRowDefinitions: Bool
        if usesLegacyInlineRows {
            usesSharedRowDefinitions = false
        } else {
            usesSharedRowDefinitions = try usesSharedInPageURLRowDefinitionStorage(db: db)
        }
        let usesURLTextWithRects = try usesURLTextInPageURLStorageWithRects(db: db)

        if usesLegacyInlineRows || usesSharedRowDefinitions || usesURLTextWithRects {
            let managesOwnTransaction = sqlite3_get_autocommit(db) != 0
            if managesOwnTransaction {
                try beginTransaction(db: db)
            }
            do {
                if usesLegacyInlineRows {
                    try migrateLegacyInPageURLRowsToURLTextStorage(db: db)
                } else if usesSharedRowDefinitions {
                    try migrateSharedInPageURLRowsToURLTextStorage(db: db)
                } else {
                    try migrateURLTextInPageURLRowsToNodeOnlyStorage(db: db)
                }
                try dropObsoleteInPageURLArtifacts(db: db)
                if managesOwnTransaction {
                    try commitTransaction(db: db)
                }
            } catch {
                if managesOwnTransaction {
                    try? rollbackTransaction(db: db)
                }
                throw error
            }
        } else {
            try createURLTextInPageURLSchema(db: db)
            try dropObsoleteInPageURLArtifacts(db: db)
        }

        if try tableExists(db: db, table: "frame_in_page_context") {
            try migrateLegacyInPageURLContextToFrame(db: db)
            try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_context;")
        }
    }

    private static func deleteInPageURLRows(db: OpaquePointer, frameId: Int64) throws {
        let sql = "DELETE FROM frame_in_page_url WHERE frameId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, frameId)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func insertInPageURLRows(
        db: OpaquePointer,
        frameId: Int64,
        rows: [FrameInPageURLRow]
    ) throws {
        let insertMappingSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, urlId, nid)
            VALUES (?, ?, ?, ?);
            """
        let insertURLTextSQL = """
            INSERT OR IGNORE INTO in_page_url_text (url)
            VALUES (?);
            """
        let selectURLTextSQL = """
            SELECT id
            FROM in_page_url_text
            WHERE url = ?
            LIMIT 1;
            """

        var insertMappingStatement: OpaquePointer?
        var insertURLTextStatement: OpaquePointer?
        var selectURLTextStatement: OpaquePointer?
        defer {
            sqlite3_finalize(insertMappingStatement)
            sqlite3_finalize(insertURLTextStatement)
            sqlite3_finalize(selectURLTextStatement)
        }

        guard sqlite3_prepare_v2(db, insertMappingSQL, -1, &insertMappingStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: insertMappingSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_prepare_v2(db, insertURLTextSQL, -1, &insertURLTextStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: insertURLTextSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_prepare_v2(db, selectURLTextSQL, -1, &selectURLTextStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: selectURLTextSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var urlTextIDs: [String: Int64] = [:]
        urlTextIDs.reserveCapacity(rows.count)

        for row in rows.sorted(by: { $0.order < $1.order }) {
            let urlID = try ensureInPageURLTextID(
                url: row.url,
                cache: &urlTextIDs,
                insertStatement: insertURLTextStatement,
                selectStatement: selectURLTextStatement
            )

            sqlite3_reset(insertMappingStatement)
            sqlite3_clear_bindings(insertMappingStatement)
            sqlite3_bind_int64(insertMappingStatement, 1, frameId)
            sqlite3_bind_int64(insertMappingStatement, 2, Int64(row.order))
            sqlite3_bind_int64(insertMappingStatement, 3, urlID)
            sqlite3_bind_int64(insertMappingStatement, 4, Int64(row.nodeID))

            guard sqlite3_step(insertMappingStatement) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: insertMappingSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func updateInPageURLState(
        db: OpaquePointer,
        frameId: Int64,
        state: FrameInPageURLState?
    ) throws {
        let sql = """
            UPDATE frame
            SET mousePosition = ?, scrollPosition = ?, videoCurrentTime = ?
            WHERE id = ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        bindTextOrNull(statement, 1, encodePoint(x: state?.mouseX, y: state?.mouseY))
        bindTextOrNull(statement, 2, encodePoint(x: state?.scrollX, y: state?.scrollY))
        bindDoubleOrNull(statement, 3, state?.videoCurrentTime)
        sqlite3_bind_int64(statement, 4, frameId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func migrateLegacyInPageURLContextToFrame(db: OpaquePointer) throws {
        let sql = """
            UPDATE frame
            SET mousePosition = COALESCE(
                    mousePosition,
                    (
                        SELECT CASE
                            WHEN c.mouseX IS NOT NULL AND c.mouseY IS NOT NULL
                                THEN CAST(c.mouseX AS TEXT) || ',' || CAST(c.mouseY AS TEXT)
                            ELSE NULL
                        END
                        FROM frame_in_page_context c
                        WHERE c.frameId = frame.id
                    )
                ),
                videoCurrentTime = COALESCE(
                    videoCurrentTime,
                    (
                        SELECT c.videoCurrentTime
                        FROM frame_in_page_context c
                        WHERE c.frameId = frame.id
                    )
                )
            WHERE EXISTS (
                SELECT 1
                FROM frame_in_page_context c
                WHERE c.frameId = frame.id
            );
            """
        try executeSQL(db: db, sql: sql)
    }

    private static func beginTransaction(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
    }

    private static func commitTransaction(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "COMMIT;")
    }

    private static func rollbackTransaction(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "ROLLBACK;")
    }

    private static func usesLegacyInPageURLRowStorage(db: OpaquePointer) throws -> Bool {
        guard try tableExists(db: db, table: "frame_in_page_url") else {
            return false
        }
        return try hasColumn(db: db, table: "frame_in_page_url", column: "url")
    }

    private static func usesSharedInPageURLRowDefinitionStorage(db: OpaquePointer) throws -> Bool {
        guard try tableExists(db: db, table: "frame_in_page_url") else {
            return false
        }
        return try hasColumn(db: db, table: "frame_in_page_url", column: "rowDefId")
    }

    private static func usesURLTextInPageURLStorageWithRects(db: OpaquePointer) throws -> Bool {
        guard try tableExists(db: db, table: "frame_in_page_url"),
              try tableExists(db: db, table: "in_page_url_text")
        else {
            return false
        }

        return try hasColumn(db: db, table: "frame_in_page_url", column: "urlId")
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "nid"))
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "x1000"))
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "y1000"))
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "w1000"))
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "h1000"))
    }

    private static func usesURLTextInPageURLStorageWithoutRects(db: OpaquePointer) throws -> Bool {
        guard try tableExists(db: db, table: "frame_in_page_url"),
              try tableExists(db: db, table: "in_page_url_text")
        else {
            return false
        }

        return try hasColumn(db: db, table: "frame_in_page_url", column: "urlId")
            && (try hasColumn(db: db, table: "frame_in_page_url", column: "nid"))
            && !(try hasColumn(db: db, table: "frame_in_page_url", column: "x1000"))
            && !(try hasColumn(db: db, table: "frame_in_page_url", column: "y1000"))
            && !(try hasColumn(db: db, table: "frame_in_page_url", column: "w1000"))
            && !(try hasColumn(db: db, table: "frame_in_page_url", column: "h1000"))
    }

    private static func createURLTextInPageURLSchema(db: OpaquePointer) throws {
        let createURLTextTable = """
            CREATE TABLE IF NOT EXISTS in_page_url_text (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL UNIQUE
            );
            """
        let createRowsTable = """
            CREATE TABLE IF NOT EXISTS frame_in_page_url (
                frameId INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                urlId INTEGER NOT NULL,
                nid INTEGER NOT NULL,
                PRIMARY KEY (frameId, ord),
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE,
                FOREIGN KEY (urlId) REFERENCES in_page_url_text(id)
            );
            """
        let createURLIDIndex = """
            CREATE INDEX IF NOT EXISTS idx_frame_in_page_url_urlId
            ON frame_in_page_url(urlId);
            """
        let createCleanupTrigger = """
            CREATE TRIGGER IF NOT EXISTS trg_frame_in_page_url_cleanup_text
            AFTER DELETE ON frame_in_page_url
            BEGIN
                DELETE FROM in_page_url_text
                WHERE id = OLD.urlId
                  AND NOT EXISTS (
                      SELECT 1
                      FROM frame_in_page_url
                      WHERE urlId = OLD.urlId
                  );
            END;
            """

        try executeSQL(db: db, sql: createURLTextTable)
        try executeSQL(db: db, sql: createRowsTable)
        try executeSQL(db: db, sql: createURLIDIndex)
        try executeSQL(db: db, sql: createCleanupTrigger)
    }

    private static func migrateLegacyInPageURLRowsToURLTextStorage(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_row_def;")
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;")
        try executeSQL(db: db, sql: "ALTER TABLE frame_in_page_url RENAME TO frame_in_page_url_legacy;")
        try createURLTextInPageURLSchema(db: db)

        let insertURLTextsSQL = """
            INSERT OR IGNORE INTO in_page_url_text (url)
            SELECT DISTINCT url
            FROM frame_in_page_url_legacy;
            """
        let insertRowsSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, urlId, nid)
            SELECT
                legacy.frameId,
                legacy.ord,
                texts.id,
                legacy.nid
            FROM frame_in_page_url_legacy legacy
            INNER JOIN in_page_url_text texts
                ON texts.url = legacy.url;
            """

        try executeSQL(db: db, sql: insertURLTextsSQL)
        try executeSQL(db: db, sql: insertRowsSQL)
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
    }

    private static func migrateSharedInPageURLRowsToURLTextStorage(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS in_page_url_row_def_legacy;")
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_row_def;")
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;")
        try executeSQL(db: db, sql: "ALTER TABLE frame_in_page_url RENAME TO frame_in_page_url_legacy;")
        try executeSQL(db: db, sql: "ALTER TABLE in_page_url_row_def RENAME TO in_page_url_row_def_legacy;")
        try createURLTextInPageURLSchema(db: db)

        let insertURLTextsSQL = """
            INSERT OR IGNORE INTO in_page_url_text (url)
            SELECT DISTINCT url
            FROM in_page_url_row_def_legacy;
            """
        let insertRowsSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, urlId, nid)
            SELECT
                legacy.frameId,
                legacy.ord,
                texts.id,
                legacy.nid
            FROM frame_in_page_url_legacy legacy
            INNER JOIN in_page_url_row_def_legacy defs
                ON defs.id = legacy.rowDefId
            INNER JOIN in_page_url_text texts
                ON texts.url = defs.url;
            """

        try executeSQL(db: db, sql: insertURLTextsSQL)
        try executeSQL(db: db, sql: insertRowsSQL)
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS in_page_url_row_def_legacy;")
    }

    private static func migrateURLTextInPageURLRowsToNodeOnlyStorage(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;")
        try executeSQL(db: db, sql: "ALTER TABLE frame_in_page_url RENAME TO frame_in_page_url_legacy;")
        try createURLTextInPageURLSchema(db: db)

        let insertRowsSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, urlId, nid)
            SELECT frameId, ord, urlId, nid
            FROM frame_in_page_url_legacy;
            """

        try executeSQL(db: db, sql: insertRowsSQL)
        try executeSQL(db: db, sql: "DROP TABLE IF EXISTS frame_in_page_url_legacy;")
    }

    private static func dropObsoleteInPageURLArtifacts(db: OpaquePointer) throws {
        try executeSQL(db: db, sql: "DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_row_def;")
        try executeSQL(db: db, sql: "DROP INDEX IF EXISTS idx_frame_in_page_url_frameId;")
        try executeSQL(db: db, sql: "DROP INDEX IF EXISTS idx_frame_in_page_url_rowDefId;")

        let usesURLTextStorageWithRects = try usesURLTextInPageURLStorageWithRects(db: db)
        let usesURLTextStorageWithoutRects = try usesURLTextInPageURLStorageWithoutRects(db: db)
        if usesURLTextStorageWithRects || usesURLTextStorageWithoutRects {
            try executeSQL(db: db, sql: "DROP TABLE IF EXISTS in_page_url_row_def;")
        }
    }

    private static func ensureInPageURLTextID(
        url: String,
        cache: inout [String: Int64],
        insertStatement: OpaquePointer?,
        selectStatement: OpaquePointer?
    ) throws -> Int64 {
        if let cachedID = cache[url] {
            return cachedID
        }

        bindTextStatement(insertStatement, text: url)
        guard sqlite3_step(insertStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: "INSERT OR IGNORE INTO in_page_url_text",
                underlying: String(cString: sqlite3_errmsg(sqlite3_db_handle(insertStatement)))
            )
        }

        bindTextStatement(selectStatement, text: url)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(
                query: "SELECT id FROM in_page_url_text",
                underlying: "Missing shared in-page URL text row"
            )
        }

        let urlTextID = sqlite3_column_int64(selectStatement, 0)
        cache[url] = urlTextID
        return urlTextID
    }

    private static func bindTextStatement(_ statement: OpaquePointer?, text: String) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
    }

    private static func executeSQL(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw DatabaseError.queryFailed(query: sql, underlying: errorMessage)
        }
    }

    private static func bindDoubleOrNull(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func encodePoint(x: Double?, y: Double?) -> String? {
        guard let x, let y else {
            return nil
        }
        return "\(x),\(y)"
    }

    private static func decodePoint(_ rawValue: String?) -> (x: Double, y: Double)? {
        guard let rawValue else {
            return nil
        }
        let parts = rawValue.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return (x, y)
    }

    private static func hasColumn(db: OpaquePointer, table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }
            if name == column {
                return true
            }
        }

        return false
    }

    private static func tableExists(db: OpaquePointer, table: String) throws -> Bool {
        let sql = """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Select by ID

    static func getByID(db: OpaquePointer, id: FrameID) throws -> FrameReference? {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.id = ?;
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

        return try parseFrameRow(statement: statement!)
    }

    // MARK: - Select by Time Range

    static func getByTimeRange(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
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
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Before Timestamp (for infinite scroll - older frames)

    static func getFramesBefore(
        db: OpaquePointer,
        timestamp: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt < ?
            ORDER BY f.createdAt DESC
            LIMIT ?;
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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select After Timestamp (for infinite scroll - newer frames)

    static func getFramesAfter(
        db: OpaquePointer,
        timestamp: Date,
        limit: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt >= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Most Recent

    static func getMostRecent(db: OpaquePointer, limit: Int) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            ORDER BY f.createdAt DESC
            LIMIT ?;
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

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select by App

    static func getByApp(
        db: OpaquePointer,
        appBundleID: String,
        limit: Int,
        offset: Int
    ) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            WHERE s.bundleID = ?
            ORDER BY f.createdAt ASC
            LIMIT ? OFFSET ?;
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
        sqlite3_bind_int(statement, 3, Int32(offset))

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Select Frames Pending Video Encoding

    /// Get frames that haven't been linked to a video yet (for video chunking)
    static func getFramesPendingVideoEncoding(db: OpaquePointer, limit: Int) throws -> [FrameReference] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.isStarred, f.encodingStatus,
                   f.redactionReason, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.videoId IS NULL
            ORDER BY f.createdAt ASC
            LIMIT ?;
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

        var frames: [FrameReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frame = try parseFrameRow(statement: statement!)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: FrameID) throws {
        let sql = "DELETE FROM frame WHERE id = ?;"

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

    static func deleteOlderThan(db: OpaquePointer, date: Date) throws -> Int {
        let sql = "DELETE FROM frame WHERE createdAt < ?;"

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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_changes(db))
    }

    /// Delete all frames newer than (after) the specified date
    /// Used for quick delete functionality to remove recent recordings
    static func deleteNewerThan(db: OpaquePointer, date: Date) throws -> Int {
        let sql = "DELETE FROM frame WHERE createdAt > ?;"

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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_changes(db))
    }

    // MARK: - Exists Check

    /// Check if a frame exists near the given timestamp (millisecond window).
    /// Used by recovery manager to avoid inserting duplicates.
    static func existsAtTimestamp(db: OpaquePointer, timestamp: Date) throws -> Bool {
        let targetMs = Schema.dateToTimestamp(timestamp)
        let toleranceMs: Int64 = 5
        let startMs = targetMs - toleranceMs
        let endMs = targetMs + toleranceMs

        let sql = "SELECT 1 FROM frame WHERE createdAt >= ? AND createdAt <= ? LIMIT 1;"

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

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)

        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Get frame ID near the given timestamp (millisecond window)
    /// Returns nil if no frame exists in that window.
    /// Used by recovery manager to update existing frames instead of skipping
    static func getFrameIDAtTimestamp(db: OpaquePointer, timestamp: Date) throws -> Int64? {
        let targetMs = Schema.dateToTimestamp(timestamp)
        let toleranceMs: Int64 = 5
        let startMs = targetMs - toleranceMs
        let endMs = targetMs + toleranceMs

        let sql = """
            SELECT id
            FROM frame
            WHERE createdAt >= ? AND createdAt <= ?
            ORDER BY ABS(createdAt - ?) ASC, id ASC
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

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)
        sqlite3_bind_int64(statement, 3, targetMs)

        if sqlite3_step(statement) == SQLITE_ROW {
            return sqlite3_column_int64(statement, 0)
        }
        return nil
    }

    // MARK: - Count

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM frame;"

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

    /// Parse a frame row from Rewind-compatible schema
    /// Expected columns: id, createdAt, segmentId, videoId, videoFrameIndex, isStarred, encodingStatus,
    ///                   redactionReason, bundleID, windowName, browserUrl (from JOIN)
    private static func parseFrameRow(statement: OpaquePointer) throws -> FrameReference {
        // Column 0: id (INTEGER)
        let frameIDValue = sqlite3_column_int64(statement, 0)
        let frameID = FrameID(value: frameIDValue)

        // Column 1: createdAt (INTEGER - ms since epoch)
        let timestampMs = sqlite3_column_int64(statement, 1)
        let timestamp = Schema.timestampToDate(timestampMs)

        // Column 2: segmentId (INTEGER - references segment.id for app session)
        let segmentIdValue = sqlite3_column_int64(statement, 2)
        let segmentID = AppSegmentID(value: segmentIdValue)

        // Column 3: videoId (INTEGER - references video.id, may be NULL)
        let videoIdValue = sqlite3_column_type(statement, 3) == SQLITE_NULL ? Int64(0) : sqlite3_column_int64(statement, 3)
        let videoID = VideoSegmentID(value: videoIdValue)

        // Column 4: videoFrameIndex (INTEGER - 0-149 position in video)
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        // Column 5: isStarred (INTEGER - 0 or 1)
        // Currently not used in FrameReference, but stored for compatibility

        // Column 6: encodingStatus (TEXT)
        let statusString = getTextOrNil(statement, 6) ?? "pending"
        let encodingStatus = EncodingStatus(rawValue: statusString) ?? .pending

        // Columns 7-10: Window redaction + metadata from segment JOIN (nullable)
        let redactionReason = getTextOrNil(statement, 7)
        let appBundleID = getTextOrNil(statement, 8)
        let windowName = getTextOrNil(statement, 9)
        let browserURL = getTextOrNil(statement, 10)

        let metadata = FrameMetadata(
            appBundleID: appBundleID,
            appName: nil, // Not stored in Rewind schema
            windowName: windowName,
            browserURL: browserURL,
            redactionReason: redactionReason
        )

        return FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .native
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

    // MARK: - Optimized Queries with Video Info (Rewind-inspired)

    /// Get frames with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getByTimeRangeWithVideoInfo(db: OpaquePointer, from startDate: Date, to endDate: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                f.encodingStatus,
                f.processingStatus,
                f.redactionReason,
                s.bundleID,
                s.windowName,
                v.path,
                v.frameRate,
                v.width,
                v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt >= ? AND f.createdAt <= ? AND f.processingStatus != 4
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            Log.error("[FrameQueries] SQL prepare failed: \(error)", category: .database)
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: error
            )
        }

        let startTimestamp = Schema.dateToTimestamp(startDate)
        let endTimestamp = Schema.dateToTimestamp(endDate)

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Get most recent frames with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getMostRecentWithVideoInfo(db: OpaquePointer, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, f.processingStatus, f.redactionReason,
                   s.bundleID, s.windowName,
                   v.path, v.frameRate, v.width, v.height, v.processingState
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, processingStatus, redactionReason
                FROM frame
                WHERE processingStatus != 4
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            Log.error("[FrameQueries] SQL prepare failed: \(error)", category: .database)
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: error
            )
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Get frames before timestamp with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getBeforeWithVideoInfo(db: OpaquePointer, timestamp: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, f.processingStatus, f.redactionReason,
                   s.bundleID, s.windowName,
                   v.path, v.frameRate, v.width, v.height, v.processingState
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, processingStatus, redactionReason
                FROM frame
                WHERE createdAt < ? AND processingStatus != 4
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Get frames after timestamp with video info in a single JOIN query (optimized, inspired by Rewind)
    static func getAfterWithVideoInfo(db: OpaquePointer, timestamp: Date, limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, f.processingStatus, f.redactionReason,
                   s.bundleID, s.windowName,
                   v.path, v.frameRate, v.width, v.height, v.processingState
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, processingStatus, redactionReason
                FROM frame
                WHERE createdAt >= ? AND processingStatus != 4
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(timestamp))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameWithVideoInfo = try parseFrameWithVideoInfoRow(statement: statement!)
            results.append(frameWithVideoInfo)
        }

        return results
    }

    /// Get a single frame by ID with video info (optimized - single query with JOINs)
    static func getByIDWithVideoInfo(db: OpaquePointer, id: FrameID) throws -> FrameWithVideoInfo? {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, f.processingStatus, f.redactionReason,
                   s.bundleID, s.windowName,
                   v.path, v.frameRate, v.width, v.height, v.processingState
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.id = ?
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

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

        return try parseFrameWithVideoInfoRow(statement: statement!)
    }

    /// Parse a row from a query that JOINs frame with segment and video tables
    /// Columns: f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, f.processingStatus,
    ///          f.redactionReason, s.bundleID, s.windowName, v.path, v.frameRate, v.width, v.height, v.processingState
    private static func parseFrameWithVideoInfoRow(statement: OpaquePointer) throws -> FrameWithVideoInfo {
        // Parse frame data
        let id = FrameID(value: sqlite3_column_int64(statement, 0))
        let timestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 1))
        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let frameIndexInSegment = Int(sqlite3_column_int(statement, 4))

        let encodingStatusText = getTextOrNil(statement, 5) ?? "pending"
        let encodingStatus = EncodingStatus(rawValue: encodingStatusText) ?? .pending
        let processingStatus = Int(sqlite3_column_int(statement, 6))
        let redactionReason = getTextOrNil(statement, 7)

        // Parse metadata from segment (columns 8-9: s.bundleID, s.windowName)
        let appBundleID = getTextOrNil(statement, 8)
        let windowName = getTextOrNil(statement, 9)

        let metadata = FrameMetadata(
            appBundleID: appBundleID,
            appName: nil,  // App name not stored in segment table
            windowName: windowName,
            browserURL: nil,  // Browser URL not stored in simple segment table
            redactionReason: redactionReason,
            displayID: 0  // Display ID not stored in segment table
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: frameIndexInSegment,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: .native
        )

        // Parse video info (columns 10-13: v.path, v.frameRate, v.width, v.height)
        var videoInfo: FrameVideoInfo? = nil
        let videoPath = getTextOrNil(statement, 10)

        if let videoPath = videoPath,
           videoID.value > 0 {
            let frameRate = sqlite3_column_double(statement, 11)
            let width = sqlite3_column_type(statement, 12) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 12))
                : nil
            let height = sqlite3_column_type(statement, 13) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 13))
                : nil
            // v.processingState: 0 = finalized/complete, 1 = still being written
            let videoProcessingState = Int(sqlite3_column_int(statement, 14))
            let isVideoFinalized = videoProcessingState == 0

            // Convert relative path to full path (must use expandedStorageRoot to resolve ~)
            let storageRoot = AppPaths.expandedStorageRoot
            let fullPath = (storageRoot as NSString).appendingPathComponent(videoPath)

            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: frameIndexInSegment,
                frameRate: frameRate,
                width: width,
                height: height,
                isVideoFinalized: isVideoFinalized
            )
        } else {
            Log.warning("[FrameQueries]   ⚠️ videoInfo is nil (videoPath=\(videoPath ?? "nil"), videoID=\(videoID.value))", category: .database)
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo, processingStatus: processingStatus)
    }

    // MARK: - Calendar Support

    /// Get all distinct dates that have frames (for calendar display)
    /// Returns dates in descending order (most recent first)
    static func getDistinctDates(db: OpaquePointer) throws -> [Date] {
        // Group by date (truncated to day) and return the first timestamp of each day
        let sql = """
            SELECT MIN(createdAt) as dayTimestamp
            FROM frame
            GROUP BY date(createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY dayTimestamp DESC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestampMs = sqlite3_column_int64(statement, 0)
            let date = Schema.timestampToDate(timestampMs)
            // Normalize to start of day in local timezone
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: date)
            dates.append(startOfDay)
        }

        return dates
    }

    /// Get distinct hours (as Date objects) for a specific day that have frames
    /// Returns times in ascending order
    static func getDistinctHoursForDate(db: OpaquePointer, date: Date) throws -> [Date] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let startMs = Schema.dateToTimestamp(startOfDay)
        let endMs = Schema.dateToTimestamp(endOfDay)

        // Group by hour and get first timestamp of each hour
        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY strftime('%H', createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY hourTimestamp ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)

        var hours: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestampMs = sqlite3_column_int64(statement, 0)
            let timestamp = Schema.timestampToDate(timestampMs)
            // Normalize to start of hour
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: timestamp)
            components.minute = 0
            components.second = 0
            if let hourDate = calendar.date(from: components) {
                hours.append(hourDate)
            }
        }

        return hours
    }
}
