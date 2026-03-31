import Foundation
import SQLCipher
import Shared

/// V19 Migration: add encodedAt timing metadata for readable frame history.
/// `encodedAt` records when a frame became readable from the encoded video file.
/// Existing rows are intentionally not backfilled because frame creation time is only an approximation.
struct V19_FrameEncodedAt: Migration {
    let version = 19

    func migrate(db: OpaquePointer) async throws {
        Log.info("🎞️ Verifying V19 encodedAt frame timing metadata...", category: .database)

        if try hasColumn(db: db, table: "frame", column: "encodedAt") {
            Log.debug("✓ frame.encodedAt already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN encodedAt INTEGER;")
            Log.debug("✓ Added frame.encodedAt column")
        }

        try execute(db: db, sql: "DROP INDEX IF EXISTS index_frame_on_encodingstatus_createdat;")
        Log.debug("✓ Dropped obsolete frame encodingStatus index if present")

        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS idx_frame_encoded_at
                ON frame(encodedAt)
                WHERE encodedAt IS NOT NULL;
                """
        )
        Log.debug("✓ Created index for frame encodedAt history lookups")

        Log.info(
            "✅ V19 migration completed: frame.encodedAt column and history index verified",
            category: .database
        )
    }

    private func hasColumn(db: OpaquePointer, table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.migrationFailed(
                version: version,
                underlying: "Failed to inspect table info: \(String(cString: sqlite3_errmsg(db)))"
            )
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
