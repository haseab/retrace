import Foundation
import SQLCipher
import Shared

/// V8 Migration: Adds long-form segment comments with many-to-many segment linking
struct V8_SegmentComments: Migration {
    let version = 8

    func migrate(db: OpaquePointer) async throws {
        Log.info("💬 Creating segment comment tables...", category: .database)

        try createSegmentCommentTable(db: db)
        try createSegmentCommentLinkTable(db: db)
        try createIndexes(db: db)

        Log.info("✅ Segment comment migration completed successfully", category: .database)
    }

    // MARK: - Tables

    private func createSegmentCommentTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS segment_comment (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                body            TEXT NOT NULL,
                author          TEXT NOT NULL,
                attachmentsJson TEXT NOT NULL DEFAULT '[]',
                createdAt       INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
                updatedAt       INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000)
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created segment_comment table")
    }

    private func createSegmentCommentLinkTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS segment_comment_link (
                commentId   INTEGER NOT NULL,
                segmentId   INTEGER NOT NULL,
                createdAt   INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
                PRIMARY KEY (commentId, segmentId),
                FOREIGN KEY (commentId) REFERENCES segment_comment(id) ON DELETE CASCADE,
                FOREIGN KEY (segmentId) REFERENCES segment(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created segment_comment_link junction table")
    }

    // MARK: - Indexes

    private func createIndexes(db: OpaquePointer) throws {
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_comment_link_on_commentid ON segment_comment_link(commentId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_comment_link_on_segmentid ON segment_comment_link(segmentId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_comment_on_createdat ON segment_comment(createdAt);")
        Log.debug("✓ Created segment_comment indexes")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 8, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
