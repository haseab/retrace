import Foundation
import SQLite3
import Shared

// MARK: - App Segment Queries

/// SQL queries for Rewind-compatible segment table (app focus sessions)
/// Owner: DATABASE agent
enum AppSegmentQueries {

    // MARK: - Insert

    static func insert(
        db: OpaquePointer,
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int = 0
    ) throws -> Int64 {
        let sql = """
            INSERT INTO segment (
                bundleID, startDate, endDate, windowName, browserUrl, type
            ) VALUES (?, ?, ?, ?, ?, ?)
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(endDate))
        bindTextOrNull(statement, 4, windowName)
        bindTextOrNull(statement, 5, browserUrl)
        sqlite3_bind_int(statement, 6, Int32(type))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    static func updateEndDate(db: OpaquePointer, id: Int64, endDate: Date) throws {
        let sql = """
            UPDATE segment
            SET endDate = ?
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

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 2, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Update browserURL if currently null
    /// Used to backfill URLs extracted from OCR after capture
    static func updateBrowserURL(db: OpaquePointer, id: Int64, browserURL: String) throws {
        let sql = """
            UPDATE segment
            SET browserUrl = ?
            WHERE id = ? AND browserUrl IS NULL
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

        sqlite3_bind_text(statement, 1, browserURL, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Select

    static func getByID(db: OpaquePointer, id: Int64) throws -> Segment? {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
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

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegment(statement: statement!)
    }

    static func getByTimeRange(db: OpaquePointer, from startDate: Date, to endDate: Date) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE startDate <= ? AND endDate >= ?
            ORDER BY startDate DESC
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

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    static func getMostRecent(db: OpaquePointer, limit: Int = 1) throws -> Segment? {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            ORDER BY startDate DESC
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

        sqlite3_bind_int(statement, 1, Int32(limit))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try parseSegment(statement: statement!)
    }

    static func getByBundleID(db: OpaquePointer, bundleID: String, limit: Int) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE bundleID = ?
            ORDER BY startDate DESC
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    static func getByBundleIDAndTimeRange(
        db: OpaquePointer,
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE bundleID = ?
              AND startDate <= ?
              AND endDate >= ?
            ORDER BY startDate DESC
            LIMIT ? OFFSET ?
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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int(statement, 4, Int32(limit))
        sqlite3_bind_int(statement, 5, Int32(offset))

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    /// Get segments filtered by bundle ID, time range, and optionally by window name or domain
    /// For browsers, filters by domain extracted from browserUrl; for other apps, filters by windowName
    static func getByBundleIDAndWindowName(
        db: OpaquePointer,
        bundleID: String,
        windowNameOrDomain: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) throws -> [Segment] {
        let isBrowser = browserBundleIDs.contains(bundleID)

        let sql: String
        if isBrowser {
            // For browsers: match domain in browserUrl using LIKE (faster than CASE expression)
            // Matches patterns like "https://domain.com/..." or "https://domain.com"
            sql = """
                SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
                FROM segment
                WHERE bundleID = ?
                  AND startDate <= ?
                  AND endDate >= ?
                  AND browserUrl IS NOT NULL
                  AND (browserUrl LIKE '%://' || ? || '/%' OR browserUrl LIKE '%://' || ? OR browserUrl LIKE '%://' || ? || '?%')
                ORDER BY startDate DESC
                LIMIT ? OFFSET ?
                """
        } else {
            // For non-browsers: match windowName exactly
            sql = """
                SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
                FROM segment
                WHERE bundleID = ?
                  AND startDate <= ?
                  AND endDate >= ?
                  AND windowName = ?
                ORDER BY startDate DESC
                LIMIT ? OFFSET ?
                """
        }

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

        sqlite3_bind_text(statement, 1, bundleID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(startDate))
        if isBrowser {
            // Browser query has 3 domain placeholders for LIKE patterns
            sqlite3_bind_text(statement, 4, windowNameOrDomain, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, windowNameOrDomain, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, windowNameOrDomain, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 7, Int32(limit))
            sqlite3_bind_int(statement, 8, Int32(offset))
        } else {
            // Non-browser query has 1 windowName placeholder
            sqlite3_bind_text(statement, 4, windowNameOrDomain, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 5, Int32(limit))
            sqlite3_bind_int(statement, 6, Int32(offset))
        }

        var results: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseSegment(statement: statement!))
        }
        return results
    }

    // MARK: - Statistics

    /// Get total captured duration in seconds (sum of all segment durations)
    static func getTotalCapturedDuration(db: OpaquePointer) throws -> TimeInterval {
        // endDate and startDate are stored as milliseconds since epoch
        let sql = "SELECT COALESCE(SUM(endDate - startDate), 0) FROM segment;"

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

        // Result is in milliseconds, convert to seconds
        let milliseconds = sqlite3_column_int64(statement, 0)
        return TimeInterval(milliseconds) / 1000.0
    }

    /// Get total captured duration in seconds for segments starting after a given date
    static func getCapturedDurationAfter(db: OpaquePointer, date: Date) throws -> TimeInterval {
        // endDate and startDate are stored as milliseconds since epoch
        let sql = "SELECT COALESCE(SUM(endDate - startDate), 0) FROM segment WHERE startDate > ?;"

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

        // Bind date as milliseconds
        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(date))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        // Result is in milliseconds, convert to seconds
        let milliseconds = sqlite3_column_int64(statement, 0)
        return TimeInterval(milliseconds) / 1000.0
    }

    static func getCount(db: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM segment;"

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

    // MARK: - App Usage Statistics

    /// Get aggregated app usage stats (duration and session count) for a time range
    /// Uses segment start/end times - NOTE: may overcount if computer is idle during a segment
    /// Sessions are counted by grouping consecutive segments of the same app
    static func getAppUsageStatsFromSegments(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(bundleID: String, duration: TimeInterval, sessionCount: Int)] {
        // Use window function to detect when bundleID changes from previous row
        // A new session starts when the app changes
        let sql = """
            WITH ordered_segments AS (
                SELECT
                    bundleID,
                    (endDate - startDate) as duration_ms,
                    LAG(bundleID) OVER (ORDER BY startDate) as prev_bundleID
                FROM segment
                WHERE startDate >= ? AND startDate <= ?
            )
            SELECT
                bundleID,
                SUM(duration_ms) as total_duration_ms,
                SUM(CASE WHEN bundleID != prev_bundleID OR prev_bundleID IS NULL THEN 1 ELSE 0 END) as session_count
            FROM ordered_segments
            GROUP BY bundleID
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

        var results: [(bundleID: String, duration: TimeInterval, sessionCount: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bundleID = String(cString: sqlite3_column_text(statement, 0))
            let durationMs = sqlite3_column_int64(statement, 1)
            let sessionCount = Int(sqlite3_column_int(statement, 2))

            results.append((
                bundleID: bundleID,
                duration: TimeInterval(durationMs) / 1000.0,
                sessionCount: sessionCount
            ))
        }
        return results
    }

    /// Browser bundle IDs that should show domain aggregation instead of window names
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",  // Arc
        "org.mozilla.firefox"
    ]

    /// Get aggregated app usage stats (duration, session count, and unique window/domain count) for a time range
    /// Calculates actual screen time from frame gaps, attributing each gap to the PREVIOUS frame's app
    /// (the app you were using during that time period)
    /// Gaps > 2 minutes are capped (considered idle time)
    /// For browsers, counts unique domains; for other apps, counts unique windowNames
    static func getAppUsageStats(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        let maxGapMs: Int64 = 120_000  // 2 minutes

        // Browser bundle IDs as SQL list for CASE expression
        let browserList = browserBundleIDs.map { "'\($0)'" }.joined(separator: ",")

        // 1. Join frames with segments to get bundleID per frame
        // 2. Calculate gaps globally (ORDER BY createdAt)
        // 3. Attribute each gap to the PREVIOUS frame's app (LAG bundleID)
        // 4. Cap gaps at maxGapMs and sum per bundleID
        // 5. Count unique windows (or domains for browsers) per bundleID
        let sql = """
            WITH frames_with_app AS (
                SELECT s.bundleID, f.createdAt
                FROM frame f
                JOIN segment s ON f.segmentId = s.id
                WHERE f.createdAt >= ? AND f.createdAt <= ?
            ),
            frame_gaps AS (
                SELECT
                    LAG(bundleID) OVER (ORDER BY createdAt) as prev_bundleID,
                    createdAt - LAG(createdAt) OVER (ORDER BY createdAt) as gap_ms
                FROM frames_with_app
            ),
            unique_items AS (
                SELECT
                    bundleID,
                    COUNT(DISTINCT CASE
                        WHEN bundleID IN (\(browserList)) THEN
                            CASE
                                WHEN browserUrl IS NOT NULL AND browserUrl != '' THEN
                                    CASE
                                        WHEN INSTR(browserUrl, '://') > 0 THEN
                                            CASE
                                                WHEN INSTR(SUBSTR(browserUrl, INSTR(browserUrl, '://') + 3), '/') > 0 THEN
                                                    SUBSTR(
                                                        browserUrl,
                                                        INSTR(browserUrl, '://') + 3,
                                                        INSTR(SUBSTR(browserUrl, INSTR(browserUrl, '://') + 3), '/') - 1
                                                    )
                                                ELSE
                                                    SUBSTR(browserUrl, INSTR(browserUrl, '://') + 3)
                                            END
                                        ELSE browserUrl
                                    END
                                ELSE NULL
                            END
                        ELSE windowName
                    END) as unique_count
                FROM segment
                WHERE startDate >= ? AND startDate <= ?
                GROUP BY bundleID
            )
            SELECT
                fg.prev_bundleID as bundleID,
                SUM(CASE
                    WHEN fg.gap_ms IS NULL THEN 0
                    WHEN fg.gap_ms > ? THEN ?
                    ELSE fg.gap_ms
                END) as duration_ms,
                COALESCE(ui.unique_count, 0) as unique_count
            FROM frame_gaps fg
            LEFT JOIN unique_items ui ON fg.prev_bundleID = ui.bundleID
            WHERE fg.prev_bundleID IS NOT NULL
            GROUP BY fg.prev_bundleID
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 4, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 5, maxGapMs)
        sqlite3_bind_int64(statement, 6, maxGapMs)

        var results: [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bundleID = String(cString: sqlite3_column_text(statement, 0))
            let durationMs = sqlite3_column_int64(statement, 1)
            let uniqueCount = Int(sqlite3_column_int(statement, 2))

            results.append((
                bundleID: bundleID,
                duration: TimeInterval(durationMs) / 1000.0,
                uniqueItemCount: uniqueCount
            ))
        }
        return results
    }

    /// Get window usage aggregated by windowName for a specific app
    /// For browsers, aggregates by domain extracted from browserUrl instead
    /// Uses frame-based calculation with 2-minute idle cap (same as getAppUsageStats)
    /// Returns windows sorted by duration descending
    static func getWindowUsageForApp(
        db: OpaquePointer,
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(windowName: String?, duration: TimeInterval)] {
        let isBrowser = browserBundleIDs.contains(bundleID)
        let maxGapMs: Int64 = 120_000  // 2 minutes

        // Frame-based calculation using GLOBAL frame ordering (same approach as getAppUsageStats):
        // 1. Get ALL frames globally with their bundleID and window/domain
        // 2. Calculate gaps between consecutive frames across ALL apps
        // 3. Attribute each gap to the PREVIOUS frame's app and window
        // 4. Filter to only include gaps where prev_bundleID matches the target
        // 5. Cap gaps at 2 minutes and sum per window/domain
        let sql: String
        if isBrowser {
            // For browsers: extract domain from browserUrl
            sql = """
                WITH all_frames AS (
                    SELECT
                        f.createdAt,
                        s.bundleID,
                        s.id as segmentId,
                        CASE
                            WHEN s.browserUrl IS NOT NULL AND s.browserUrl != '' THEN
                                CASE
                                    WHEN INSTR(s.browserUrl, '://') > 0 THEN
                                        CASE
                                            WHEN INSTR(SUBSTR(s.browserUrl, INSTR(s.browserUrl, '://') + 3), '/') > 0 THEN
                                                SUBSTR(
                                                    s.browserUrl,
                                                    INSTR(s.browserUrl, '://') + 3,
                                                    INSTR(SUBSTR(s.browserUrl, INSTR(s.browserUrl, '://') + 3), '/') - 1
                                                )
                                            ELSE
                                                SUBSTR(s.browserUrl, INSTR(s.browserUrl, '://') + 3)
                                        END
                                    ELSE s.browserUrl
                                END
                            ELSE NULL
                        END as item_name
                    FROM frame f
                    JOIN segment s ON f.segmentId = s.id
                    WHERE f.createdAt >= ? AND f.createdAt <= ?
                ),
                frame_gaps AS (
                    SELECT
                        LAG(bundleID) OVER (ORDER BY createdAt) as prev_bundleID,
                        LAG(segmentId) OVER (ORDER BY createdAt) as prev_segmentId,
                        LAG(item_name) OVER (ORDER BY createdAt) as prev_item,
                        createdAt - LAG(createdAt) OVER (ORDER BY createdAt) as gap_ms
                    FROM all_frames
                )
                SELECT
                    prev_item as item_name,
                    SUM(CASE
                        WHEN gap_ms IS NULL THEN 0
                        WHEN gap_ms > ? THEN ?
                        ELSE gap_ms
                    END) as duration_ms
                FROM frame_gaps
                WHERE prev_bundleID = ?
                    AND prev_item IS NOT NULL
                    AND NOT EXISTS (
                        SELECT 1 FROM segment_tag st
                        JOIN tag t ON st.tagId = t.id
                        WHERE st.segmentId = prev_segmentId AND t.name = 'hidden'
                    )
                GROUP BY prev_item
                HAVING duration_ms >= 1000
                ORDER BY duration_ms DESC
                """
        } else {
            // For non-browsers: use windowName
            sql = """
                WITH all_frames AS (
                    SELECT
                        f.createdAt,
                        s.bundleID,
                        s.id as segmentId,
                        s.windowName as item_name
                    FROM frame f
                    JOIN segment s ON f.segmentId = s.id
                    WHERE f.createdAt >= ? AND f.createdAt <= ?
                ),
                frame_gaps AS (
                    SELECT
                        LAG(bundleID) OVER (ORDER BY createdAt) as prev_bundleID,
                        LAG(segmentId) OVER (ORDER BY createdAt) as prev_segmentId,
                        LAG(item_name) OVER (ORDER BY createdAt) as prev_item,
                        createdAt - LAG(createdAt) OVER (ORDER BY createdAt) as gap_ms
                    FROM all_frames
                )
                SELECT
                    prev_item as item_name,
                    SUM(CASE
                        WHEN gap_ms IS NULL THEN 0
                        WHEN gap_ms > ? THEN ?
                        ELSE gap_ms
                    END) as duration_ms
                FROM frame_gaps
                WHERE prev_bundleID = ?
                    AND prev_item IS NOT NULL
                    AND NOT EXISTS (
                        SELECT 1 FROM segment_tag st
                        JOIN tag t ON st.tagId = t.id
                        WHERE st.segmentId = prev_segmentId AND t.name = 'hidden'
                    )
                GROUP BY prev_item
                HAVING duration_ms >= 1000
                ORDER BY duration_ms DESC
                """
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 3, maxGapMs)
        sqlite3_bind_int64(statement, 4, maxGapMs)
        sqlite3_bind_text(statement, 5, (bundleID as NSString).utf8String, -1, nil)

        var results: [(windowName: String?, duration: TimeInterval)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let windowName: String?
            if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                windowName = nil
            } else {
                windowName = String(cString: sqlite3_column_text(statement, 0))
            }
            let durationMs = sqlite3_column_int64(statement, 1)

            results.append((
                windowName: windowName,
                duration: TimeInterval(durationMs) / 1000.0
            ))
        }
        return results
    }

    /// Get daily screen time totals for a date range (for 7-day graphs)
    /// Uses segment start/end times - NOTE: may overcount if computer is idle during a segment
    /// Returns array of (date, tenthsOfHours) tuples sorted by date ascending, grouped by local timezone
    static func getDailyScreenTimeFromSegments(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(date: Date, value: Int64)] {
        // Get local timezone offset in milliseconds
        let tzOffsetMs = Int64(TimeZone.current.secondsFromGMT()) * 1000

        // Group segments by local day by adding timezone offset before grouping
        let sql = """
            SELECT
                ((startDate + ?) / 86400000) * 86400000 - ? as day,
                SUM(endDate - startDate) as total_duration_ms
            FROM segment
            WHERE startDate >= ? AND startDate <= ?
            GROUP BY ((startDate + ?) / 86400000)
            ORDER BY day ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tzOffsetMs)
        sqlite3_bind_int64(statement, 2, tzOffsetMs)
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 4, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 5, tzOffsetMs)

        var results: [(date: Date, value: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dayTimestamp = sqlite3_column_int64(statement, 0)
            let durationMs = sqlite3_column_int64(statement, 1)
            let date = Date(timeIntervalSince1970: Double(dayTimestamp) / 1000)
            // Convert milliseconds to tenths of hours for graph display (allows 1 decimal place)
            let tenthsOfHours = durationMs / (1000 * 60 * 6)
            results.append((date: date, value: tenthsOfHours))
        }

        return results
    }

    /// Get daily screen time totals for a date range (for 7-day graphs)
    /// Calculates actual screen time from frame gaps, capping gaps > 5 minutes as idle
    /// Returns array of (date, tenthsOfHours) tuples sorted by date ascending, grouped by local timezone
    static func getDailyScreenTime(
        db: OpaquePointer,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(date: Date, value: Int64)] {
        // Get local timezone offset in milliseconds
        let tzOffsetMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        let maxGapMs: Int64 = 120_000  // 2 minutes - gaps larger than this are considered idle

        // Calculate screen time from frame gaps, grouped by local day
        // Uses LAG to get previous frame time, then caps gaps at 5 minutes
        let sql = """
            WITH frame_gaps AS (
                SELECT
                    createdAt,
                    ((createdAt + ?) / 86400000) as local_day,
                    createdAt - LAG(createdAt) OVER (ORDER BY createdAt) as gap_ms
                FROM frame
                WHERE createdAt >= ? AND createdAt <= ?
            )
            SELECT
                (local_day * 86400000) - ? as day,
                SUM(CASE
                    WHEN gap_ms IS NULL THEN 0
                    WHEN gap_ms > ? THEN ?
                    ELSE gap_ms
                END) as total_duration_ms
            FROM frame_gaps
            GROUP BY local_day
            ORDER BY day ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tzOffsetMs)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(statement, 3, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int64(statement, 4, tzOffsetMs)
        sqlite3_bind_int64(statement, 5, maxGapMs)
        sqlite3_bind_int64(statement, 6, maxGapMs)

        var results: [(date: Date, value: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dayTimestamp = sqlite3_column_int64(statement, 0)
            let durationMs = sqlite3_column_int64(statement, 1)
            let date = Date(timeIntervalSince1970: Double(dayTimestamp) / 1000)
            // Return raw milliseconds - conversion happens in UI layer to preserve precision
            results.append((date: date, value: durationMs))
        }

        return results
    }

    // MARK: - Delete

    static func delete(db: OpaquePointer, id: Int64) throws {
        let sql = "DELETE FROM segment WHERE id = ?"

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

    // MARK: - Helper

    private static func parseSegment(statement: OpaquePointer) throws -> Segment {
        let id = sqlite3_column_int64(statement, 0)
        let bundleID = String(cString: sqlite3_column_text(statement, 1))
        let startDate = Schema.timestampToDate(sqlite3_column_int64(statement, 2))
        let endDate = Schema.timestampToDate(sqlite3_column_int64(statement, 3))
        let windowName = sqlite3_column_type(statement, 4) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 4))
            : nil
        let browserUrl = sqlite3_column_type(statement, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 5))
            : nil
        let type = Int(sqlite3_column_int(statement, 6))

        return Segment(
            id: SegmentID(value: id),
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
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
