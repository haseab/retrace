import Foundation
import SQLCipher
import Shared

/// CRUD operations for frames table
enum FrameQueries {

    // MARK: - Insert

    static func insert(db: OpaquePointer, frame: FrameReference) throws {
        let sql = """
            INSERT INTO frames (
                id, segment_id, session_id, timestamp, frame_index, encoding_status,
                app_bundle_id, app_name, window_name, browser_url, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        sqlite3_bind_text(statement, 1, frame.id.stringValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, frame.segmentID.stringValue, -1, SQLITE_TRANSIENT)
        bindTextOrNull(statement, 3, frame.sessionID?.stringValue)
        sqlite3_bind_int64(statement, 4, Schema.dateToTimestamp(frame.timestamp))
        sqlite3_bind_int(statement, 5, Int32(frame.frameIndexInSegment))
        sqlite3_bind_text(statement, 6, frame.encodingStatus.rawValue, -1, SQLITE_TRANSIENT)
        bindTextOrNull(statement, 7, frame.metadata.appBundleID)
        bindTextOrNull(statement, 8, frame.metadata.appName)
        bindTextOrNull(statement, 9, frame.metadata.windowName)
        bindTextOrNull(statement, 10, frame.metadata.browserURL)
        sqlite3_bind_text(statement, 11, frame.source.rawValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select by ID

    static func getByID(db: OpaquePointer, id: FrameID) throws -> FrameReference? {
        let sql = """
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
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
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC
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
        // Get frames BEFORE the timestamp, ordered DESC (newest first of the older batch)
        // This returns frames in descending order, caller should reverse if needed
        let sql = """
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
            WHERE timestamp < ?
            ORDER BY timestamp DESC
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
        // Get frames AFTER the timestamp, ordered ASC (oldest first of the newer batch)
        let sql = """
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
            WHERE timestamp > ?
            ORDER BY timestamp ASC
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
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
            ORDER BY timestamp DESC
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
            SELECT id, segment_id, session_id, timestamp, frame_index, encoding_status,
                   app_bundle_id, app_name, window_name, browser_url, source
            FROM frames
            WHERE app_bundle_id = ?
            ORDER BY timestamp ASC
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

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: FrameID) throws {
        let sql = "DELETE FROM frames WHERE id = ?;"

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

    static func deleteOlderThan(db: OpaquePointer, date: Date) throws -> Int {
        let sql = "DELETE FROM frames WHERE timestamp < ?;"

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

    // MARK: - Count

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM frames;"

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

    private static func parseFrameRow(statement: OpaquePointer) throws -> FrameReference {
        // Column 0: id
        guard let idString = sqlite3_column_text(statement, 0) else {
            throw DatabaseError.queryFailed(query: "parseFrameRow", underlying: "Missing frame ID")
        }
        guard let frameID = FrameID(string: String(cString: idString)) else {
            throw DatabaseError.queryFailed(query: "parseFrameRow", underlying: "Invalid frame ID")
        }

        // Column 1: segment_id
        guard let segmentString = sqlite3_column_text(statement, 1) else {
            throw DatabaseError.queryFailed(query: "parseFrameRow", underlying: "Missing segment ID")
        }
        guard let segmentUUID = UUID(uuidString: String(cString: segmentString)) else {
            throw DatabaseError.queryFailed(query: "parseFrameRow", underlying: "Invalid segment ID")
        }
        let segmentID = SegmentID(value: segmentUUID)

        // Column 2: session_id (nullable)
        var sessionID: AppSessionID? = nil
        if let sessionString = sqlite3_column_text(statement, 2) {
            if let sessionUUID = UUID(uuidString: String(cString: sessionString)) {
                sessionID = AppSessionID(value: sessionUUID)
            }
        }

        // Column 3: timestamp
        let timestampMs = sqlite3_column_int64(statement, 3)
        let timestamp = Schema.timestampToDate(timestampMs)

        // Column 4: frame_index
        let frameIndex = Int(sqlite3_column_int(statement, 4))

        // Column 5: encoding_status
        let statusString = getTextOrNil(statement, 5) ?? "pending"
        let encodingStatus = EncodingStatus(rawValue: statusString) ?? .pending

        // Columns 6-9: metadata (nullable)
        let appBundleID = getTextOrNil(statement, 6)
        let appName = getTextOrNil(statement, 7)
        let windowName = getTextOrNil(statement, 8)
        let browserURL = getTextOrNil(statement, 9)

        // Column 10: source
        let sourceString = getTextOrNil(statement, 10) ?? "native"
        let source = FrameSource(rawValue: sourceString) ?? .native

        let metadata = FrameMetadata(
            appBundleID: appBundleID,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL
        )

        return FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: segmentID,
            sessionID: sessionID,
            frameIndexInSegment: frameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: source
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
