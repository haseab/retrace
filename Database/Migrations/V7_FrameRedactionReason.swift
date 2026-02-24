import Foundation
import SQLCipher
import Shared

/// V7 Migration: Add redactionReason column to frame table
/// Stores why a frame was redacted at capture time.
struct V7_FrameRedactionReason: Migration {
    let version = 7

    func migrate(db: OpaquePointer) async throws {
        Log.info("🔒 Adding redactionReason column to frame table...", category: .database)

        if try hasColumn(db: db, table: "frame", column: "redactionReason") {
            Log.info("✓ frame.redactionReason already exists, skipping", category: .database)
            return
        }

        try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN redactionReason TEXT;")
        Log.debug("✓ Added redactionReason column to frame table")

        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_frame_redaction_reason ON frame(redactionReason) WHERE redactionReason IS NOT NULL;"
        )
        Log.debug("✓ Created index on redactionReason")

        Log.info("✅ V7 migration completed: frame.redactionReason column added", category: .database)
    }

    // MARK: - Helpers

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
