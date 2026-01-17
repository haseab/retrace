import Foundation
import SQLCipher
import Shared

/// Unified database adapter for all data sources
/// Consolidates all duplicate query logic between RetraceDataSource and RewindDataSource
/// Uses DatabaseConnection for abstraction and DatabaseConfig for source-specific differences
public actor UnifiedDatabaseAdapter {

    // MARK: - Properties

    private let connection: DatabaseConnection
    private let config: DatabaseConfig

    // MARK: - Initialization

    public init(connection: DatabaseConnection, config: DatabaseConfig) {
        self.connection = connection
        self.config = config
    }

    // MARK: - Frame Retrieval Queries

    /// Get frames within a time range with video info (optimized with JOINs)
    public func getFramesWithVideoInfo(
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> [FrameWithVideoInfo] {
        // Apply cutoff date if applicable
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else {
            return []
        }

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                f.encodingStatus,
                s.bundleID,
                s.windowName,
                s.browserUrl,
                v.path,
                v.frameRate,
                v.width,
                v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        // Bind date parameters using config-specific format
        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(effectiveEndDate, to: statement, at: 2)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Get most recent frames with video info (optimized with subquery + JOIN)
    public func getMostRecentFramesWithVideoInfo(limit: Int) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Get frames before a timestamp (infinite scroll backward)
    public func getFramesWithVideoInfoBefore(
        timestamp: Date,
        limit: Int
    ) throws -> [FrameWithVideoInfo] {
        // Apply cutoff date if applicable
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt < ?
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        config.bindDate(effectiveTimestamp, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Get frames after a timestamp (infinite scroll forward)
    public func getFramesWithVideoInfoAfter(
        timestamp: Date,
        limit: Int
    ) throws -> [FrameWithVideoInfo] {
        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus,
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus
                FROM frame
                WHERE createdAt > ?
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Get video info for a specific frame by video segment ID and timestamp
    /// Note: The segmentID parameter is for API compatibility - the query primarily uses timestamp
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date) throws -> FrameVideoInfo? {
        // Query by timestamp - this matches both Rewind and Retrace behavior
        let sql = """
            SELECT v.id, v.path, v.width, v.height, v.frameRate, f.videoFrameIndex
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return nil
        }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try? parseFrameVideoInfo(statement: statement)
    }

    // MARK: - Segment Retrieval Queries

    /// Get segments (app sessions) within a time range
    public func getSegments(from startDate: Date, to endDate: Date) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE startDate >= ? AND startDate <= ?
            ORDER BY startDate ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(endDate, to: statement, at: 2)

        var segments: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let segment = try? parseSegment(statement: statement) {
                segments.append(segment)
            }
        }

        return segments
    }

    // MARK: - OCR Node Queries

    /// Get all OCR nodes for a specific frame
    public func getAllOCRNodes(frameID: FrameID) throws -> [OCRNodeWithText] {
        // Query nodes with text via doc_segment -> searchRanking_content join
        // Uses correct column names: leftX, topY, textOffset, textLength
        let sql = """
            SELECT
                n.id,
                n.nodeOrder,
                n.textOffset,
                n.textLength,
                n.leftX,
                n.topY,
                n.width,
                n.height,
                sc.c0
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var nodes: [OCRNodeWithText] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let node = parseOCRNodeFromRow(statement: statement) {
                nodes.append(node)
            }
        }

        return nodes
    }

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date) throws -> [OCRNodeWithText] {
        // First find the frame ID
        let frameSql = """
            SELECT id FROM frame WHERE createdAt = ? LIMIT 1;
            """

        guard let frameStatement = try? connection.prepare(sql: frameSql) else {
            return []
        }
        defer { connection.finalize(frameStatement) }

        config.bindDate(timestamp, to: frameStatement, at: 1)

        guard sqlite3_step(frameStatement) == SQLITE_ROW else {
            return []
        }

        let frameID = FrameID(value: sqlite3_column_int64(frameStatement, 0))
        return try getAllOCRNodes(frameID: frameID)
    }

    // MARK: - Deletion

    /// Delete a single frame (with cascading to nodes and doc_segment)
    public func deleteFrame(frameID: FrameID) throws {
        try deleteFrames(frameIDs: [frameID])
    }

    /// Delete multiple frames in a transaction
    public func deleteFrames(frameIDs: [FrameID]) throws {
        guard !frameIDs.isEmpty else { return }

        try connection.beginTransaction()

        do {
            for frameID in frameIDs {
                // Delete OCR nodes
                let deleteNodesSql = "DELETE FROM node WHERE frameId = ?;"
                if let stmt = try? connection.prepare(sql: deleteNodesSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }

                // Delete doc_segment entries
                let deleteDocSegmentSql = "DELETE FROM doc_segment WHERE frameId = ?;"
                if let stmt = try? connection.prepare(sql: deleteDocSegmentSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }

                // Delete frame itself
                let deleteFrameSql = "DELETE FROM frame WHERE id = ?;"
                if let stmt = try? connection.prepare(sql: deleteFrameSql) {
                    sqlite3_bind_int64(stmt, 1, frameID.value)
                    sqlite3_step(stmt)
                    connection.finalize(stmt)
                }
            }

            try connection.commit()
        } catch {
            try connection.rollback()
            throw error
        }
    }

    // MARK: - Row Parsing

    private func parseFrameWithVideoInfo(statement: OpaquePointer) throws -> FrameWithVideoInfo {
        // Parse frame columns
        let id = FrameID(value: sqlite3_column_int64(statement, 0))

        guard let timestamp = config.parseDate(from: statement, column: 1) else {
            throw DatabaseConnectionError.executionFailed(
                sql: "parseFrameWithVideoInfo",
                error: "Failed to parse timestamp"
            )
        }

        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        let encodingStatusText = sqlite3_column_text(statement, 5)
        let encodingStatusString = encodingStatusText != nil ? String(cString: encodingStatusText!) : "pending"
        let encodingStatus = EncodingStatus(rawValue: encodingStatusString) ?? .pending

        // Parse segment columns
        let bundleID = getTextOrNil(statement, 6) ?? ""
        let windowName = getTextOrNil(statement, 7)
        let browserUrl = getTextOrNil(statement, 8)

        // Parse video columns
        let videoPath = getTextOrNil(statement, 9)
        let frameRate = sqlite3_column_type(statement, 10) != SQLITE_NULL
            ? sqlite3_column_double(statement, 10)
            : nil
        let width = sqlite3_column_type(statement, 11) != SQLITE_NULL
            ? Int(sqlite3_column_int(statement, 11))
            : nil
        let height = sqlite3_column_type(statement, 12) != SQLITE_NULL
            ? Int(sqlite3_column_int(statement, 12))
            : nil

        // Build metadata from segment columns
        let metadata = FrameMetadata(
            appBundleID: bundleID.isEmpty ? nil : bundleID,
            appName: bundleID.components(separatedBy: ".").last,
            windowName: windowName,
            browserURL: browserUrl,
            displayID: 0
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: config.source
        )

        let videoInfo: FrameVideoInfo?
        if let relativePath = videoPath,
           let rate = frameRate,
           let w = width,
           let h = height {
            // Construct full path from storage root + relative path
            let fullPath = "\(config.storageRoot)/\(relativePath)"
            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: videoFrameIndex,
                frameRate: rate,
                width: w,
                height: h
            )
        } else {
            // Log why videoInfo is nil
            print("[UnifiedDatabaseAdapter] Frame \(id.value) videoInfo=nil: path=\(videoPath ?? "nil"), frameRate=\(frameRate.map { String($0) } ?? "nil"), width=\(width.map { String($0) } ?? "nil"), height=\(height.map { String($0) } ?? "nil")")
            videoInfo = nil
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo)
    }

    private func parseFrameVideoInfo(statement: OpaquePointer) throws -> FrameVideoInfo {
        guard let relativePath = getTextOrNil(statement, 1) else {
            throw DatabaseConnectionError.executionFailed(
                sql: "parseFrameVideoInfo",
                error: "Missing video path"
            )
        }

        let width = Int(sqlite3_column_int(statement, 2))
        let height = Int(sqlite3_column_int(statement, 3))
        let frameRate = sqlite3_column_double(statement, 4)
        let frameIndex = Int(sqlite3_column_int(statement, 5))

        // Construct full path from storage root + relative path
        let fullPath = "\(config.storageRoot)/\(relativePath)"

        return FrameVideoInfo(
            videoPath: fullPath,
            frameIndex: frameIndex,
            frameRate: frameRate,
            width: width,
            height: height
        )
    }

    private func parseSegment(statement: OpaquePointer) throws -> Segment {
        let id = SegmentID(value: sqlite3_column_int64(statement, 0))
        let bundleID = getTextOrNil(statement, 1) ?? ""

        guard let startDate = config.parseDate(from: statement, column: 2),
              let endDate = config.parseDate(from: statement, column: 3) else {
            throw DatabaseConnectionError.executionFailed(
                sql: "parseSegment",
                error: "Failed to parse dates"
            )
        }

        let windowName = getTextOrNil(statement, 4)
        let browserUrl = getTextOrNil(statement, 5)
        let type = Int(sqlite3_column_int(statement, 6))

        return Segment(
            id: id,
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }

    /// Parse an OCR node from the query result row
    /// Expected column order: id, nodeOrder, textOffset, textLength, leftX, topY, width, height, c0 (full text)
    private func parseOCRNodeFromRow(statement: OpaquePointer) -> OCRNodeWithText? {
        let id = Int(sqlite3_column_int64(statement, 0))
        let textOffset = Int(sqlite3_column_int(statement, 2))
        let textLength = Int(sqlite3_column_int(statement, 3))
        let leftX = sqlite3_column_double(statement, 4)
        let topY = sqlite3_column_double(statement, 5)
        let width = sqlite3_column_double(statement, 6)
        let height = sqlite3_column_double(statement, 7)

        // Extract text substring from full FTS content
        guard let fullTextCStr = sqlite3_column_text(statement, 8) else { return nil }
        let fullText = String(cString: fullTextCStr)

        let startIndex = fullText.index(
            fullText.startIndex,
            offsetBy: textOffset,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        let endIndex = fullText.index(
            startIndex,
            offsetBy: textLength,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        let text = String(fullText[startIndex..<endIndex])

        return OCRNodeWithText(
            id: id,
            x: leftX,
            y: topY,
            width: width,
            height: height,
            text: text
        )
    }

    // MARK: - Full-Text Search

    /// Search using FTS5 with BM25 ranking
    /// Supports two modes:
    /// - .relevant: Top N by BM25 relevance, then sorted by date (fast, best matches)
    /// - .all: All matches sorted by date using subquery (slower, chronological)
    public func search(query: SearchQuery) throws -> SearchResults {
        switch query.mode {
        case .relevant:
            return try searchRelevant(query: query)
        case .all:
            return try searchAll(query: query)
        }
    }

    /// Relevant search: Top N by BM25, then sorted by date
    /// Two-phase approach for speed
    private func searchRelevant(query: SearchQuery) throws -> SearchResults {
        let startTime = Date()
        Log.info("[UnifiedAdapter] Relevant search for: '\(query.text)' source=\(config.source)", category: .app)

        let ftsQuery = buildFTSQuery(query.text)
        Log.debug("[UnifiedAdapter] FTS query: '\(ftsQuery)'", category: .app)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Phase 1: Pure FTS search - get top 50 by relevance
        let phase1Start = Date()
        let relevanceLimit = 50  // Cap relevant results
        let ftsSQL = """
            SELECT rowid, snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet, bm25(searchRanking) as rank
            FROM searchRanking
            WHERE searchRanking MATCH ?
            ORDER BY bm25(searchRanking)
            LIMIT ?
        """

        guard let ftsStatement = try? connection.prepare(sql: ftsSQL) else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(ftsStatement) }

        sqlite3_bind_text(ftsStatement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(ftsStatement, 2, Int32(relevanceLimit))

        var ftsResults: [(rowid: Int64, snippet: String, rank: Double)] = []
        while sqlite3_step(ftsStatement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(ftsStatement, 0)
            let snippet = sqlite3_column_text(ftsStatement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(ftsStatement, 2)
            ftsResults.append((rowid: rowid, snippet: snippet, rank: rank))
        }

        let phase1Elapsed = Int(Date().timeIntervalSince(phase1Start) * 1000)
        Log.info("[UnifiedAdapter] Phase 1 (FTS): Found \(ftsResults.count) matches in \(phase1Elapsed)ms", category: .app)

        guard !ftsResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: elapsed)
        }

        // Phase 2: Join to get metadata, sorted by date, with pagination and filters
        let phase2Start = Date()
        let rowids = ftsResults.map { $0.rowid }
        let rowidPlaceholders = rowids.map { _ in "?" }.joined(separator: ", ")

        // Build dynamic WHERE clause based on filters
        var whereConditions = ["ds.docid IN (\(rowidPlaceholders))"]
        var extraBindValues: [Any] = []

        // Apply cutoff date if applicable
        if let cutoffDate = config.cutoffDate {
            whereConditions.append("f.createdAt < ?")
            extraBindValues.append(config.formatDate(cutoffDate))
        }

        // Date range filters
        if let startDate = query.filters.startDate {
            whereConditions.append("f.createdAt >= ?")
            extraBindValues.append(config.formatDate(startDate))
        }
        if let endDate = query.filters.endDate {
            whereConditions.append("f.createdAt <= ?")
            extraBindValues.append(config.formatDate(endDate))
        }

        // App filter
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let appPlaceholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            whereConditions.append("s.bundleID IN (\(appPlaceholders))")
            extraBindValues.append(contentsOf: appBundleIDs)
        }

        let whereClause = whereConditions.joined(separator: " AND ")

        let metadataSQL = """
            SELECT
                ds.docid,
                f.id as frame_id,
                f.createdAt as timestamp,
                s.id as segment_id,
                s.bundleID as app_bundle_id,
                s.windowName as window_title,
                f.videoId as video_id,
                f.videoFrameIndex as frame_index
            FROM doc_segment ds
            JOIN frame f ON ds.frameId = f.id
            JOIN segment s ON f.segmentId = s.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ? OFFSET ?
        """

        guard let metaStatement = try? connection.prepare(sql: metadataSQL) else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: elapsed)
        }
        defer { connection.finalize(metaStatement) }

        // Bind rowids first
        var bindIndex: Int32 = 1
        for rowid in rowids {
            sqlite3_bind_int64(metaStatement, bindIndex, rowid)
            bindIndex += 1
        }

        // Bind extra values (cutoff date, filter dates, app bundle IDs)
        for value in extraBindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(metaStatement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(metaStatement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        // Bind limit and offset
        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(metaStatement, bindIndex, Int32(query.offset))

        let ftsLookup = Dictionary(uniqueKeysWithValues: ftsResults.map { ($0.rowid, (snippet: $0.snippet, rank: $0.rank)) })

        var results: [SearchResult] = []

        while sqlite3_step(metaStatement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(metaStatement, 0)
            let frameId = sqlite3_column_int64(metaStatement, 1)
            let segmentId = sqlite3_column_int64(metaStatement, 3)
            let appBundleID = sqlite3_column_text(metaStatement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(metaStatement, 5).map { String(cString: $0) }
            let videoId = sqlite3_column_int64(metaStatement, 6)
            let frameIndex = Int(sqlite3_column_int(metaStatement, 7))

            guard let ftsData = ftsLookup[docid] else { continue }
            let snippet = ftsData.snippet
            let rank = ftsData.rank

            let appName = appBundleID?.components(separatedBy: ".").last
            let timestamp = config.parseDate(from: metaStatement, column: 2) ?? Date()

            let frameID = FrameID(value: frameId)

            let cleanSnippet = snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: frameID,
                timestamp: timestamp,
                snippet: cleanSnippet,
                matchedText: query.text,
                relevanceScore: abs(rank) / (1.0 + abs(rank)),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: segmentId),
                videoID: VideoSegmentID(value: videoId),
                frameIndex: frameIndex,
                source: config.source
            )

            results.append(result)
        }

        let phase2Elapsed = Int(Date().timeIntervalSince(phase2Start) * 1000)
        let totalElapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        Log.info("[UnifiedAdapter] Relevant search: \(results.count) results in \(totalElapsed)ms (phase1=\(phase1Elapsed)ms, phase2=\(phase2Elapsed)ms)", category: .app)

        // Total count is capped at relevanceLimit for this mode
        let totalCount = min(ftsResults.count, relevanceLimit)

        return SearchResults(
            query: query,
            results: results,
            totalCount: totalCount,
            searchTimeMs: totalElapsed
        )
    }

    /// All search: Chronological results using subquery for efficiency
    /// FTS filters first, then minimal joins for date sorting
    private func searchAll(query: SearchQuery) throws -> SearchResults {
        let startTime = Date()
        Log.info("[UnifiedAdapter] All search for: '\(query.text)' source=\(config.source)", category: .app)

        let ftsQuery = buildFTSQuery(query.text)
        Log.debug("[UnifiedAdapter] FTS query: '\(ftsQuery)'", category: .app)

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Build dynamic WHERE clause based on filters
        var whereConditions: [String] = []
        var bindValues: [Any] = []

        // Apply cutoff date if applicable
        if let cutoffDate = config.cutoffDate {
            whereConditions.append("f.createdAt < ?")
            bindValues.append(config.formatDate(cutoffDate))
        }

        // Date range filters
        if let startDate = query.filters.startDate {
            whereConditions.append("f.createdAt >= ?")
            bindValues.append(config.formatDate(startDate))
        }
        if let endDate = query.filters.endDate {
            whereConditions.append("f.createdAt <= ?")
            bindValues.append(config.formatDate(endDate))
        }

        // App filter - need to join segment table
        let needsSegmentJoin = query.filters.appBundleIDs != nil
        var appFilterClause = ""
        if let appBundleIDs = query.filters.appBundleIDs, !appBundleIDs.isEmpty {
            let placeholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
            appFilterClause = "AND s.bundleID IN (\(placeholders))"
            bindValues.append(contentsOf: appBundleIDs)
        }

        let whereClause = whereConditions.isEmpty ? "1=1" : whereConditions.joined(separator: " AND ")

        // OPTIMIZED: Get recent frames FIRST (limited set), THEN join with FTS
        // This avoids sorting all 200k+ FTS matches by limiting to recent 10k frames first
        let recentFramesLimit = 10000  // Only search within most recent 10k frames

        let sql: String
        if needsSegmentJoin {
            sql = """
                SELECT
                    ds.docid as docid,
                    snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet,
                    bm25(searchRanking) as rank,
                    recent_frames.frame_id,
                    recent_frames.timestamp,
                    recent_frames.segment_id,
                    recent_frames.video_id,
                    recent_frames.frame_index
                FROM (
                    SELECT f.id as frame_id, f.createdAt as timestamp, f.segmentId as segment_id, f.videoId as video_id, f.videoFrameIndex as frame_index
                    FROM frame f
                    JOIN segment s ON f.segmentId = s.id
                    WHERE \(whereClause) \(appFilterClause)
                    ORDER BY f.createdAt DESC
                    LIMIT \(recentFramesLimit)
                ) recent_frames
                JOIN doc_segment ds ON ds.frameId = recent_frames.frame_id
                JOIN searchRanking ON searchRanking.rowid = ds.docid
                WHERE searchRanking MATCH ?
                ORDER BY recent_frames.timestamp DESC
                LIMIT ? OFFSET ?
            """
        } else {
            sql = """
                SELECT
                    ds.docid as docid,
                    snippet(searchRanking, 0, '<mark>', '</mark>', '...', 32) as snippet,
                    bm25(searchRanking) as rank,
                    recent_frames.frame_id,
                    recent_frames.timestamp,
                    recent_frames.segment_id,
                    recent_frames.video_id,
                    recent_frames.frame_index
                FROM (
                    SELECT f.id as frame_id, f.createdAt as timestamp, f.segmentId as segment_id, f.videoId as video_id, f.videoFrameIndex as frame_index
                    FROM frame f
                    WHERE \(whereClause)
                    ORDER BY f.createdAt DESC
                    LIMIT \(recentFramesLimit)
                ) recent_frames
                JOIN doc_segment ds ON ds.frameId = recent_frames.frame_id
                JOIN searchRanking ON searchRanking.rowid = ds.docid
                WHERE searchRanking MATCH ?
                ORDER BY recent_frames.timestamp DESC
                LIMIT ? OFFSET ?
            """
        }

        guard let statement = try? connection.prepare(sql: sql) else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        defer { connection.finalize(statement) }

        // Bind parameters (order changed: date filters first, then FTS query)
        var bindIndex: Int32 = 1

        // First: bind date/app filters for the recent_frames subquery
        for value in bindValues {
            if let stringValue = value as? String {
                sqlite3_bind_text(statement, bindIndex, stringValue, -1, SQLITE_TRANSIENT)
            } else if let intValue = value as? Int64 {
                sqlite3_bind_int64(statement, bindIndex, intValue)
            }
            bindIndex += 1
        }

        // Then: bind FTS query
        sqlite3_bind_text(statement, bindIndex, ftsQuery, -1, SQLITE_TRANSIENT)
        bindIndex += 1

        // Finally: bind limit and offset
        sqlite3_bind_int(statement, bindIndex, Int32(query.limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(query.offset))

        Log.debug("[UnifiedAdapter] Executing SQL query...", category: .app)

        // Collect frame results (without segment metadata yet)
        var frameResults: [(docid: Int64, snippet: String, rank: Double, frameId: Int64, timestamp: Date, segmentId: Int64, videoId: Int64, frameIndex: Int)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let docid = sqlite3_column_int64(statement, 0)
            let snippet = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(statement, 2)
            let frameId = sqlite3_column_int64(statement, 3)
            let segmentId = sqlite3_column_int64(statement, 5)
            let videoId = sqlite3_column_int64(statement, 6)
            let frameIndex = Int(sqlite3_column_int(statement, 7))

            let timestamp = config.parseDate(from: statement, column: 4) ?? Date()
            frameResults.append((docid: docid, snippet: snippet, rank: rank, frameId: frameId, timestamp: timestamp, segmentId: segmentId, videoId: videoId, frameIndex: frameIndex))
        }

        guard !frameResults.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let totalCount = getSearchTotalCount(ftsQuery: ftsQuery)
            Log.info("[UnifiedAdapter] All search: 0 results in \(elapsed)ms", category: .app)
            return SearchResults(query: query, results: [], totalCount: totalCount, searchTimeMs: elapsed)
        }

        Log.debug("[UnifiedAdapter] Found \(frameResults.count) frame results, fetching segment metadata...", category: .app)

        // Fetch segment metadata for just these results
        let segmentIds = Array(Set(frameResults.map { $0.segmentId }))
        Log.debug("[UnifiedAdapter] Fetching metadata for \(segmentIds.count) unique segments", category: .app)
        let segmentMetadata = fetchSegmentMetadata(segmentIds: segmentIds)
        Log.debug("[UnifiedAdapter] Segment metadata fetched, building results...", category: .app)

        var results: [SearchResult] = []

        for frame in frameResults {
            let segmentMeta = segmentMetadata[frame.segmentId]
            let appBundleID = segmentMeta?.bundleID
            let windowName = segmentMeta?.windowName
            let appName = appBundleID?.components(separatedBy: ".").last

            let frameID = FrameID(value: frame.frameId)

            let cleanSnippet = frame.snippet
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")

            let result = SearchResult(
                id: frameID,
                timestamp: frame.timestamp,
                snippet: cleanSnippet,
                matchedText: query.text,
                relevanceScore: abs(frame.rank) / (1.0 + abs(frame.rank)),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: nil,
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: frame.segmentId),
                videoID: VideoSegmentID(value: frame.videoId),
                frameIndex: frame.frameIndex,
                source: config.source
            )

            results.append(result)
        }

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        Log.info("[UnifiedAdapter] All search: \(results.count) results in \(elapsed)ms", category: .app)

        let totalCount = getSearchTotalCount(ftsQuery: ftsQuery)

        return SearchResults(
            query: query,
            results: results,
            totalCount: totalCount,
            searchTimeMs: elapsed
        )
    }

    /// Fetch segment metadata for a batch of segment IDs
    private func fetchSegmentMetadata(segmentIds: [Int64]) -> [Int64: (bundleID: String?, windowName: String?)] {
        guard !segmentIds.isEmpty else { return [:] }

        let placeholders = segmentIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, bundleID, windowName FROM segment WHERE id IN (\(placeholders))"

        guard let statement = try? connection.prepare(sql: sql) else {
            return [:]
        }
        defer { connection.finalize(statement) }

        for (index, segmentId) in segmentIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), segmentId)
        }

        var metadata: [Int64: (bundleID: String?, windowName: String?)] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            metadata[id] = (bundleID: bundleID, windowName: windowName)
        }

        return metadata
    }

    /// Build FTS5 query from user input
    private func buildFTSQuery(_ text: String) -> String {
        // Split into words and create FTS5 query
        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word -> String in
                // Escape special FTS5 characters
                let escaped = word
                    .replacingOccurrences(of: "\"", with: "\"\"")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: ":", with: "")
                // Add prefix wildcard for partial matching
                return "\"\(escaped)\"*"
            }

        return words.joined(separator: " ")
    }

    /// Get total count of search results (FTS-only, no joins for speed)
    private func getSearchTotalCount(ftsQuery: String) -> Int {
        let countSQL = """
            SELECT COUNT(*)
            FROM searchRanking
            WHERE searchRanking MATCH ?
        """

        guard let countStmt = try? connection.prepare(sql: countSQL) else {
            return 0
        }
        defer { connection.finalize(countStmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(countStmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)

        if sqlite3_step(countStmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(countStmt, 0))
        }

        return 0
    }

    // MARK: - URL Bounding Box Detection

    /// Get bounding box for URL in a frame's OCR text
    /// Searches for browser URL bar by matching domain against OCR nodes
    public func getURLBoundingBox(timestamp: Date) throws -> URLBoundingBox? {
        // Get frameId and browserUrl
        let frameSQL = """
            SELECT f.id, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let frameStmt = try? connection.prepare(sql: frameSQL) else {
            return nil
        }
        defer { connection.finalize(frameStmt) }

        config.bindDate(timestamp, to: frameStmt, at: 1)

        guard sqlite3_step(frameStmt) == SQLITE_ROW else {
            return nil
        }

        let frameId = sqlite3_column_int64(frameStmt, 0)
        guard let browserUrlPtr = sqlite3_column_text(frameStmt, 1) else {
            return nil
        }
        let browserUrl = String(cString: browserUrlPtr)
        guard !browserUrl.isEmpty else { return nil }

        // Get FTS content
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        guard let ftsStmt = try? connection.prepare(sql: ftsSQL) else {
            return nil
        }
        defer { connection.finalize(ftsStmt) }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else {
            return nil
        }

        let c0Text = sqlite3_column_text(ftsStmt, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text

        // Get nodes
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        guard let nodesStmt = try? connection.prepare(sql: nodesSQL) else {
            return nil
        }
        defer { connection.finalize(nodesStmt) }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        let domain = URL(string: browserUrl)?.host ?? browserUrl
        var bestMatch: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let textOffset = Int(sqlite3_column_int(nodesStmt, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt, 6))

            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])
            guard nodeText.lowercased().contains(domain.lowercased()) else { continue }

            var score = 0
            let urlRatio = Double(domain.count) / Double(nodeText.count)
            if urlRatio > 0.6 { score += 100 }
            else if urlRatio > 0.3 { score += 50 }
            else { score += 10 }

            if topY > 0.07 && topY < 0.15 { score += 50 }
            else if topY < 0.07 { score += 20 }

            if nodeText.contains("/") && !nodeText.contains(" ") { score += 30 }

            if let current = bestMatch {
                if score > current.score {
                    bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
                }
            } else {
                bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
            }
        }

        guard let bounds = bestMatch else { return nil }

        return URLBoundingBox(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            url: browserUrl
        )
    }

    // MARK: - App Discovery

    /// Get distinct apps from the segment table, ordered by usage count
    /// Returns bundle IDs only - name resolution should be done at the caller level
    public func getDistinctApps(limit: Int = 100) throws -> [String] {
        let sql = """
            SELECT bundleID, COUNT(*) as usage_count
            FROM segment
            WHERE bundleID IS NOT NULL AND bundleID != ''
            GROUP BY bundleID
            ORDER BY usage_count DESC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var bundleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIDPtr = sqlite3_column_text(statement, 0) else { continue }
            bundleIDs.append(String(cString: bundleIDPtr))
        }

        return bundleIDs
    }

    // MARK: - Helpers

    private func getTextOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        guard let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }
}
