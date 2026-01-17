import Foundation
import SQLCipher
import Shared

/// Full-text search manager implementing FTSProtocol
/// Owner: DATABASE agent
public actor FTSManager: FTSProtocol {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let databasePath: String

    // MARK: - Initialization

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// Convenience initializer for in-memory database (testing)
    public init() {
        self.databasePath = ":memory:"
    }

    /// Initialize the FTS manager (opens existing database connection)
    public func initialize() async throws {
        let expandedPath = NSString(string: databasePath).expandingTildeInPath

        // Use sqlite3_open_v2 with SQLITE_OPEN_URI to support URI filenames like:
        // file:memdb_xxx?mode=memory&cache=shared (used by tests to share one in-memory DB)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        guard sqlite3_open_v2(expandedPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }
    }

    /// Close the database connection
    public func close() async throws {
        guard let db = db else { return }

        // `sqlite3_close_v2` safely performs a deferred close if any internal FTS5 resources
        // are still being cleaned up.
        let rc = sqlite3_close_v2(db)
        guard rc == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.connectionFailed(underlying: "Failed to close FTS database (\(rc)): \(errorMsg)")
        }

        self.db = nil
    }

    // MARK: - Search Operations

    public func search(query: String, limit: Int, offset: Int) async throws -> [FTSMatch] {
        return try await search(query: query, filters: .none, limit: limit, offset: offset)
    }

    public func search(
        query: String,
        filters: SearchFilters,
        limit: Int,
        offset: Int
    ) async throws -> [FTSMatch] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "FTS database not initialized")
        }

        // Build the SQL query with optional filters
        let sql = buildSearchQuery(filters: filters)

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
        var bindIndex: Int32 = 1

        // Bind FTS query
        sqlite3_bind_text(statement, bindIndex, query, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        // Bind filter parameters
        if let startDate = filters.startDate {
            sqlite3_bind_int64(statement, bindIndex, Schema.dateToTimestamp(startDate))
            bindIndex += 1
        }

        if let endDate = filters.endDate {
            sqlite3_bind_int64(statement, bindIndex, Schema.dateToTimestamp(endDate))
            bindIndex += 1
        }

        // Bind app filter parameters
        if let appBundleIDs = filters.appBundleIDs, !appBundleIDs.isEmpty {
            for appID in appBundleIDs {
                // Bind for app_name LIKE ? (use wildcards for partial matching)
                let appPattern = "%\(appID)%"
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
                // Bind for app_bundle_id LIKE ?
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        if let excludedAppBundleIDs = filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            for appID in excludedAppBundleIDs {
                let appPattern = "%\(appID)%"
                // Bind for app_name NOT LIKE ?
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
                // Bind for app_bundle_id NOT LIKE ?
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        // Bind limit and offset
        sqlite3_bind_int(statement, bindIndex, Int32(limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(offset))

        // Execute and collect results
        var matches: [FTSMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let match = try parseSearchResult(statement: statement!)
            matches.append(match)
        }

        return matches
    }

    public func getMatchCount(query: String, filters: SearchFilters) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "FTS database not initialized")
        }

        // Build count query
        let sql = buildCountQuery(filters: filters)

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

        // Bind parameters (similar to search)
        var bindIndex: Int32 = 1

        sqlite3_bind_text(statement, bindIndex, query, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        if let startDate = filters.startDate {
            sqlite3_bind_int64(statement, bindIndex, Schema.dateToTimestamp(startDate))
            bindIndex += 1
        }

        if let endDate = filters.endDate {
            sqlite3_bind_int64(statement, bindIndex, Schema.dateToTimestamp(endDate))
            bindIndex += 1
        }

        // Bind app filter parameters (same as search)
        if let appBundleIDs = filters.appBundleIDs, !appBundleIDs.isEmpty {
            for appID in appBundleIDs {
                let appPattern = "%\(appID)%"
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        if let excludedAppBundleIDs = filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            for appID in excludedAppBundleIDs {
                let appPattern = "%\(appID)%"
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
                sqlite3_bind_text(statement, bindIndex, appPattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    public func rebuildIndex() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "FTS database not initialized")
        }

        // Rebuild the FTS index from scratch
        let sql = "INSERT INTO searchRanking(searchRanking) VALUES('rebuild');"

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    public func optimizeIndex() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "FTS database not initialized")
        }

        // Optimize the FTS index (merge segments)
        let sql = "INSERT INTO searchRanking(searchRanking) VALUES('optimize');"

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    // MARK: - Private Helpers

    private func buildSearchQuery(filters: SearchFilters) -> String {
        // Rewind schema join pattern: searchRanking → searchRanking_content → doc_segment → frame → segment
        var sql = """
            SELECT
                c.id, ds.frameId, f.createdAt, s.bundleID, s.windowName,
                snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet,
                bm25(searchRanking) as rank,
                f.videoId, f.videoFrameIndex
            FROM searchRanking
            JOIN searchRanking_content c ON searchRanking.rowid = c.id
            JOIN doc_segment ds ON c.id = ds.docid
            JOIN frame f ON ds.frameId = f.id
            JOIN segment s ON f.segmentId = s.id
            WHERE searchRanking MATCH ?
            """

        // Add time filters (using frame.createdAt)
        if filters.startDate != nil {
            sql += " AND f.createdAt >= ?"
        }

        if filters.endDate != nil {
            sql += " AND f.createdAt <= ?"
        }

        // Add app filtering (using segment.bundleID and segment.windowName)
        if let appBundleIDs = filters.appBundleIDs, !appBundleIDs.isEmpty {
            let placeholders = appBundleIDs.map { _ in "(s.bundleID LIKE ? OR s.windowName LIKE ?)" }.joined(separator: " OR ")
            sql += " AND (\(placeholders))"
        }

        if let excludedAppBundleIDs = filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            let placeholders = excludedAppBundleIDs.map { _ in "(s.bundleID NOT LIKE ? AND s.windowName NOT LIKE ?)" }.joined(separator: " AND ")
            sql += " AND (\(placeholders))"
        }

        sql += " ORDER BY rank LIMIT ? OFFSET ?"

        return sql
    }

    private func buildCountQuery(filters: SearchFilters) -> String {
        // Same join pattern as buildSearchQuery
        var sql = """
            SELECT COUNT(*)
            FROM searchRanking
            JOIN searchRanking_content c ON searchRanking.rowid = c.id
            JOIN doc_segment ds ON c.id = ds.docid
            JOIN frame f ON ds.frameId = f.id
            JOIN segment s ON f.segmentId = s.id
            WHERE searchRanking MATCH ?
            """

        if filters.startDate != nil {
            sql += " AND f.createdAt >= ?"
        }

        if filters.endDate != nil {
            sql += " AND f.createdAt <= ?"
        }

        if let appBundleIDs = filters.appBundleIDs, !appBundleIDs.isEmpty {
            let placeholders = appBundleIDs.map { _ in "(s.bundleID LIKE ? OR s.windowName LIKE ?)" }.joined(separator: " OR ")
            sql += " AND (\(placeholders))"
        }

        if let excludedAppBundleIDs = filters.excludedAppBundleIDs, !excludedAppBundleIDs.isEmpty {
            let placeholders = excludedAppBundleIDs.map { _ in "(s.bundleID NOT LIKE ? AND s.windowName NOT LIKE ?)" }.joined(separator: " AND ")
            sql += " AND (\(placeholders))"
        }

        return sql
    }

    private func parseSearchResult(statement: OpaquePointer) throws -> FTSMatch {
        // New column order from Rewind schema:
        // c.id, ds.frameId, f.createdAt, s.bundleID, s.windowName, snippet, rank, f.videoId, f.videoFrameIndex

        // Column 0: document id (searchRanking_content.id)
        let documentID = sqlite3_column_int64(statement, 0)

        // Column 1: frame_id (INTEGER from doc_segment.frameId)
        let frameIDValue = sqlite3_column_int64(statement, 1)
        let frameID = FrameID(value: frameIDValue)

        // Column 2: timestamp (frame.createdAt)
        let timestampMs = sqlite3_column_int64(statement, 2)
        let timestamp = Schema.timestampToDate(timestampMs)

        // Column 3: bundleID (segment.bundleID) - use as appName
        var appName: String?
        if let bundleIDText = sqlite3_column_text(statement, 3) {
            appName = String(cString: bundleIDText)
        }

        // Column 4: windowName (segment.windowName)
        var windowName: String?
        if let windowNameText = sqlite3_column_text(statement, 4) {
            windowName = String(cString: windowNameText)
        }

        // Column 5: snippet
        guard let snippetText = sqlite3_column_text(statement, 5) else {
            throw DatabaseError.queryFailed(query: "parseSearchResult", underlying: "Missing snippet")
        }
        let snippet = String(cString: snippetText)

        // Column 6: rank (BM25 score - negative, lower is better)
        let rank = sqlite3_column_double(statement, 6)

        // Column 7: videoId (INTEGER from frame.videoId)
        let videoIDValue = sqlite3_column_int64(statement, 7)
        let videoID = VideoSegmentID(value: videoIDValue)

        // Column 8: videoFrameIndex (INTEGER from frame.videoFrameIndex)
        let frameIndex = Int(sqlite3_column_int(statement, 8))

        Log.debug("[FTSManager] Parsed FTS result: frameID=\(frameID.value), videoID=\(videoIDValue), frameIndex=\(frameIndex), snippet='\(snippet.prefix(50))...'", category: .database)

        return FTSMatch(
            documentID: documentID,
            frameID: frameID,
            timestamp: timestamp,
            snippet: snippet,
            rank: rank,
            appName: appName,
            windowName: windowName,
            videoID: videoID,
            frameIndex: frameIndex
        )
    }
}
