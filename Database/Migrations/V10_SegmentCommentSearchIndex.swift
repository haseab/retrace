import Foundation
import SQLCipher
import Shared

/// V10 Migration: add FTS5 index for efficient server-side comment search.
struct V10_SegmentCommentSearchIndex: Migration {
    let version = 10

    func migrate(db: OpaquePointer) async throws {
        Log.info("🔎 Building segment comment search index...", category: .database)

        try execute(db: db, sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS segment_comment_fts USING fts5(
                body,
                content='segment_comment',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            """)

        // Drop first so the trigger body can evolve safely across versions.
        try execute(db: db, sql: "DROP TRIGGER IF EXISTS segment_comment_ai;")
        try execute(db: db, sql: "DROP TRIGGER IF EXISTS segment_comment_ad;")
        try execute(db: db, sql: "DROP TRIGGER IF EXISTS segment_comment_au;")

        try execute(db: db, sql: """
            CREATE TRIGGER segment_comment_ai AFTER INSERT ON segment_comment BEGIN
                INSERT INTO segment_comment_fts(rowid, body) VALUES (new.id, new.body);
            END;
            """)

        try execute(db: db, sql: """
            CREATE TRIGGER segment_comment_ad AFTER DELETE ON segment_comment BEGIN
                INSERT INTO segment_comment_fts(segment_comment_fts, rowid, body)
                VALUES ('delete', old.id, old.body);
            END;
            """)

        try execute(db: db, sql: """
            CREATE TRIGGER segment_comment_au AFTER UPDATE OF body ON segment_comment BEGIN
                INSERT INTO segment_comment_fts(segment_comment_fts, rowid, body)
                VALUES ('delete', old.id, old.body);
                INSERT INTO segment_comment_fts(rowid, body) VALUES (new.id, new.body);
            END;
            """)

        // Rebuild keeps index consistent for existing rows on upgrade.
        try execute(
            db: db,
            sql: "INSERT INTO segment_comment_fts(segment_comment_fts) VALUES ('rebuild');"
        )

        Log.info("✅ V10 migration completed: segment_comment_fts ready", category: .database)
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
