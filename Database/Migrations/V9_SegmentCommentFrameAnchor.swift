import Foundation
import SQLCipher
import Shared

/// V9 Migration: add optional frame anchor to segment comments.
struct V9_SegmentCommentFrameAnchor: Migration {
    let version = 9

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧷 Adding frame anchor column to segment comments...", category: .database)

        if try hasColumn(db: db, table: "segment_comment", column: "frameId") {
            Log.info("✓ segment_comment.frameId already exists, skipping", category: .database)
            try execute(
                db: db,
                sql: "CREATE INDEX IF NOT EXISTS index_segment_comment_on_frameid ON segment_comment(frameId);"
            )
            return
        }

        try execute(
            db: db,
            sql: """
                ALTER TABLE segment_comment
                ADD COLUMN frameId INTEGER REFERENCES frame(id) ON DELETE SET NULL;
                """
        )
        Log.debug("✓ Added frameId column to segment_comment table")

        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS index_segment_comment_on_frameid ON segment_comment(frameId);"
        )
        Log.debug("✓ Created index on segment_comment.frameId")

        Log.info("✅ V9 migration completed: segment_comment.frameId added", category: .database)
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
