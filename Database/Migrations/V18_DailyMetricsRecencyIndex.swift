import Foundation
import SQLCipher
import Shared

/// V18 Migration: add the recency index used by latest daily-metrics lookups.
struct V18_DailyMetricsRecencyIndex: Migration {
    let version = 18

    func migrate(db: OpaquePointer) async throws {
        Log.info("📈 Verifying V18 daily_metrics recency index...", category: .database)

        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS index_daily_metrics_on_timestamp_id_desc
                ON daily_metrics(timestamp DESC, id DESC);
                """
        )

        Log.info(
            "✅ V18 migration completed: daily_metrics(timestamp DESC, id DESC) index verified",
            category: .database
        )
    }

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: version, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
