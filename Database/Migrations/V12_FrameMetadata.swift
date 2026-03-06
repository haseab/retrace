import Foundation
import SQLCipher
import Shared

/// V12 Migration: Add metadata + in-page capture columns to frame table.
/// Stores optional JSON payload for browser-derived per-frame metadata and
/// resolved per-frame browser state directly on frame rows.
struct V12_FrameMetadata: Migration {
    let version = 12

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧩 Ensuring frame metadata + in-page URL schema...", category: .database)

        if !((try? hasColumn(db: db, table: "frame", column: "metadata")) ?? false) {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN metadata TEXT;")
            Log.info("✓ Added frame.metadata column", category: .database)
        } else {
            Log.info("✓ frame.metadata already exists", category: .database)
        }

        if !((try? hasColumn(db: db, table: "frame", column: "mousePosition")) ?? false) {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN mousePosition TEXT;")
            Log.info("✓ Added frame.mousePosition column", category: .database)
        } else {
            Log.info("✓ frame.mousePosition already exists", category: .database)
        }

        if !((try? hasColumn(db: db, table: "frame", column: "scrollPosition")) ?? false) {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN scrollPosition TEXT;")
            Log.info("✓ Added frame.scrollPosition column", category: .database)
        } else {
            Log.info("✓ frame.scrollPosition already exists", category: .database)
        }

        if !((try? hasColumn(db: db, table: "frame", column: "videoCurrentTime")) ?? false) {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN videoCurrentTime REAL;")
            Log.info("✓ Added frame.videoCurrentTime column", category: .database)
        } else {
            Log.info("✓ frame.videoCurrentTime already exists", category: .database)
        }

        try FrameQueries.ensureInPageURLSchema(db: db)

        Log.info("✅ V12 migration completed: frame metadata + in-page URL schema ready", category: .database)
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
