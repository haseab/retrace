import Foundation
import SQLCipher
import Shared

/// V15 Migration: Add protected OCR text storage and generic frame rewrite metadata.
/// - `node.encryptedText` stores the protected OCR payload for redacted nodes.
/// - `frame.rewritePurpose` records why a frame entered the generic rewrite/re-encode lane.
/// - `frame.rewrittenAt` records when a rewrite completed successfully.
struct V15_NodeRedactionFlag: Migration {
    let version = 15

    func migrate(db: OpaquePointer) async throws {
        Log.info("🔒 Verifying V15 rewrite/protected-text schema...", category: .database)

        if try hasColumn(db: db, table: "node", column: "encryptedText") {
            Log.debug("✓ node.encryptedText already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE node ADD COLUMN encryptedText TEXT;")
            Log.debug("✓ Added node.encryptedText column")
        }

        if try hasColumn(db: db, table: "frame", column: "rewritePurpose") {
            Log.debug("✓ frame.rewritePurpose already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN rewritePurpose TEXT;")
            Log.debug("✓ Added frame.rewritePurpose column")
        }

        if try hasColumn(db: db, table: "frame", column: "rewrittenAt") {
            Log.debug("✓ frame.rewrittenAt already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN rewrittenAt INTEGER;")
            Log.debug("✓ Added frame.rewrittenAt column")
        }

        try execute(db: db, sql: "DROP INDEX IF EXISTS idx_node_redacted_frameid;")
        Log.debug("✓ Dropped legacy redacted-node index if present")

        if try hasColumn(db: db, table: "node", column: "redacted") {
            do {
                try execute(db: db, sql: "ALTER TABLE node DROP COLUMN redacted;")
                Log.debug("✓ Dropped legacy node.redacted column")
            } catch {
                Log.warning("⚠️ Failed to drop legacy node.redacted column: \(error.localizedDescription)", category: .database)
            }
        }

        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_node_encrypted_frameid ON node(frameId) WHERE encryptedText IS NOT NULL;"
        )
        Log.debug("✓ Created index for protected OCR nodes")

        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS idx_frame_rewrite_purpose_status_video
                ON frame(rewritePurpose, processingStatus, videoId)
                WHERE rewritePurpose IS NOT NULL;
                """
        )
        Log.debug("✓ Created index for frame rewrite-purpose lookups")

        Log.info(
            "✅ V15 migration completed: protected OCR text and rewrite timing metadata verified",
            category: .database
        )
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
