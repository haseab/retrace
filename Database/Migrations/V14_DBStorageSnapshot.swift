import Foundation
import SQLCipher
import Shared

/// V14 Migration: Adds db_storage_snapshot table for one-row-per-day DB/WAL size snapshots.
struct V14_DBStorageSnapshot: Migration {
    let version = 14

    func migrate(db: OpaquePointer) async throws {
        Log.info("🗄️ Creating db storage snapshot table...", category: .database)

        try createDBStorageSnapshotTable(db: db)
        try createIndexes(db: db)

        Log.info("✅ DB storage snapshot migration completed successfully", category: .database)
    }

    private func createDBStorageSnapshotTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS db_storage_snapshot (
                local_day   TEXT PRIMARY KEY,
                db_bytes    INTEGER NOT NULL,
                wal_bytes   INTEGER NOT NULL,
                sampled_at  INTEGER NOT NULL
            );
            """
        try execute(db: db, sql: sql)
    }

    private func createIndexes(db: OpaquePointer) throws {
        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS index_db_storage_snapshot_on_sampled_at
                ON db_storage_snapshot(sampled_at);
                """
        )
    }

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 14, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
