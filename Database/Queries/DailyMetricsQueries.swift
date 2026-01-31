import Foundation
import SQLite3
import Shared

// MARK: - Daily Metrics Queries

/// SQL queries for daily_metrics table
/// Tracks engagement events (timeline opens, searches, text copies) as individual rows
/// Owner: DATABASE agent
public enum DailyMetricsQueries {

    // MARK: - Metric Types

    /// Standard metric type identifiers
    public enum MetricType: String {
        case timelineOpens = "timeline_opens"
        case searches = "searches"
        case textCopies = "text_copies"

        // New metrics for Retrace Wrapped
        case imageCopies = "image_copies"
        case imageSaves = "image_saves"
        case deeplinkCopies = "deeplink_copies"
        case timelineSessionDuration = "timeline_session_duration"  // metadata: duration in ms
        case filteredSearchQuery = "filtered_search_query"  // metadata: JSON {query, filters}
        case timelineFilterQuery = "timeline_filter_query"  // metadata: JSON {bundleID, windowName, browserUrl, startDate, endDate}
        case scrubDistance = "scrub_distance"  // metadata: distance in pixels per session
        case searchDialogOpens = "search_dialog_opens"
        case ocrReprocessRequests = "ocr_reprocess_requests"
        case arrowKeyNavigation = "arrow_key_navigation"  // metadata: "left" or "right"
        case shiftDragZoomRegion = "shift_drag_zoom_region"  // metadata: JSON {region, screenSize}
        case shiftDragTextCopy = "shift_drag_text_copy"  // metadata: copied text
        case appLaunches = "app_launches"
        case keyboardShortcut = "keyboard_shortcut"  // metadata: shortcut identifier (e.g. "cmd+c", "cmd+f")
    }

    // MARK: - Insert

    /// Record a single metric event
    static func recordEvent(
        db: OpaquePointer,
        metricType: MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) throws {
        let timestampMs = Int64(timestamp.timeIntervalSince1970 * 1000)

        let sql = """
            INSERT INTO daily_metrics (metricType, timestamp, metadata)
            VALUES (?, ?, ?)
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, timestampMs)

        if let metadata = metadata {
            sqlite3_bind_text(statement, 3, metadata, -1, SQLITE_TRANSIENT)
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

    // MARK: - Query

    /// Get daily counts for a metric type within a date range (for 7-day graphs)
    /// Returns array of (date, count) tuples sorted by date ascending, grouped by local timezone
    static func getDailyCounts(
        db: OpaquePointer,
        metricType: MetricType,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(date: Date, value: Int64)] {
        let startTimestamp = startOfDay(startDate)
        let endTimestamp = endOfDay(endDate)

        // Get local timezone offset in milliseconds
        let tzOffsetMs = Int64(TimeZone.current.secondsFromGMT()) * 1000

        // Group by local day by adding timezone offset before grouping
        let sql = """
            SELECT
                ((timestamp + ?) / 86400000) * 86400000 - ? as day,
                COUNT(*) as count
            FROM daily_metrics
            WHERE metricType = ? AND timestamp >= ? AND timestamp <= ?
            GROUP BY ((timestamp + ?) / 86400000)
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

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, tzOffsetMs)
        sqlite3_bind_int64(statement, 2, tzOffsetMs)
        sqlite3_bind_text(statement, 3, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, startTimestamp)
        sqlite3_bind_int64(statement, 5, endTimestamp)
        sqlite3_bind_int64(statement, 6, tzOffsetMs)

        var results: [(date: Date, value: Int64)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let dayTimestamp = sqlite3_column_int64(statement, 0)
            let count = sqlite3_column_int64(statement, 1)
            let date = Date(timeIntervalSince1970: Double(dayTimestamp) / 1000)
            results.append((date: date, value: count))
        }

        return results
    }

    /// Get total count of a metric for a date range
    static func getTotalCount(
        db: OpaquePointer,
        metricType: MetricType,
        from startDate: Date,
        to endDate: Date
    ) throws -> Int64 {
        let startTimestamp = startOfDay(startDate)
        let endTimestamp = endOfDay(endDate)

        let sql = """
            SELECT COUNT(*)
            FROM daily_metrics
            WHERE metricType = ? AND timestamp >= ? AND timestamp <= ?
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int64(statement, 3, endTimestamp)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Helpers

    /// Get timestamp for start of day (midnight) in milliseconds
    private static func startOfDay(_ date: Date) -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return Int64(startOfDay.timeIntervalSince1970 * 1000)
    }

    /// Get timestamp for end of day (23:59:59.999) in milliseconds
    private static func endOfDay(_ date: Date) -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-0.001)
        return Int64(endOfDay.timeIntervalSince1970 * 1000)
    }
}
