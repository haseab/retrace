import Foundation
import SQLCipher
import Shared

/// V4 Migration: Adds daily_metrics table for tracking engagement events
/// Each row is a single event (timeline open, search, text copy) with exact timestamp
struct V4_DailyMetrics: Migration {
    let version = 4

    func migrate(db: OpaquePointer) async throws {
        Log.info("📊 Creating daily metrics table...", category: .database)

        try createDailyMetricsTable(db: db)
        try createIndexes(db: db)

        Log.info("✅ Daily metrics migration completed successfully", category: .database)
    }

    // MARK: - Tables

    private func createDailyMetricsTable(db: OpaquePointer) throws {
        // Table for storing individual metric events
        // Each row represents one event (e.g., one timeline open, one search)
        // - metricType: string identifier (e.g., "timeline_opens", "searches", "text_copies")
        // - timestamp: exact time of the event (stored as INTEGER, milliseconds since epoch)
        // - metadata: optional JSON for additional context (e.g., search terms, copied text)
        let sql = """
            CREATE TABLE IF NOT EXISTS daily_metrics (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                metricType  TEXT NOT NULL,
                timestamp   INTEGER NOT NULL,
                metadata    TEXT
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created daily_metrics table")
    }

    // MARK: - Indexes

    private func createIndexes(db: OpaquePointer) throws {
        // Composite index for querying specific metric type within date range
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_daily_metrics_on_type_timestamp ON daily_metrics(metricType, timestamp);")

        // Composite index for efficient window usage queries (bundleID + startDate range)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_on_bundleid_startdate ON segment(bundleID, startDate);")

        Log.debug("✓ Created daily_metrics indexes")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 4, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
