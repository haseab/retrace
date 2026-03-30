import Foundation
import SQLCipher
import Shared

/// V17 Migration: Add capture_trigger column to frame table.
/// Stores the coarse-grained trigger category for persisted native frames.
struct V17_FrameCaptureTrigger: Migration {
    let version = 17

    func migrate(db: OpaquePointer) async throws {
        Log.info("🎯 Adding capture_trigger column to frame table...", category: .database)

        if try hasColumn(db: db, table: "frame", column: "capture_trigger") {
            Log.info("✓ frame.capture_trigger already exists, skipping", category: .database)
            return
        }

        try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN capture_trigger TEXT;")
        Log.debug("✓ Added frame.capture_trigger column to frame table")

        Log.info("✅ V17 migration completed: frame.capture_trigger column added", category: .database)
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
