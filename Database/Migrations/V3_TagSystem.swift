import Foundation
import SQLCipher
import Shared

/// V3 Migration: Adds tag system for segment tagging
/// Creates tag table and segment_tag junction table for many-to-many relationship
struct V3_TagSystem: Migration {
    let version = 3

    func migrate(db: OpaquePointer) async throws {
        Log.info("🏷️ Creating tag system tables...", category: .database)

        try createTagTable(db: db)
        try createSegmentTagTable(db: db)
        try createIndexes(db: db)
        try seedHiddenTag(db: db)

        Log.info("✅ Tag system migration completed successfully", category: .database)
    }

    // MARK: - Tables

    private func createTagTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS tag (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                name    TEXT NOT NULL UNIQUE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created tag table")
    }

    private func createSegmentTagTable(db: OpaquePointer) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS segment_tag (
                segmentId   INTEGER NOT NULL,
                tagId       INTEGER NOT NULL,
                createdAt   INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
                PRIMARY KEY (segmentId, tagId),
                FOREIGN KEY (segmentId) REFERENCES segment(id) ON DELETE CASCADE,
                FOREIGN KEY (tagId) REFERENCES tag(id) ON DELETE CASCADE
            );
            """
        try execute(db: db, sql: sql)
        Log.debug("✓ Created segment_tag junction table")
    }

    // MARK: - Indexes

    private func createIndexes(db: OpaquePointer) throws {
        // Index for efficient "get all segments with tag X" queries
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_tag_on_tagid ON segment_tag(tagId);")
        // Index for efficient "get all tags for segment X" queries
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS index_segment_tag_on_segmentid ON segment_tag(segmentId);")
        Log.debug("✓ Created segment_tag indexes")
    }

    // MARK: - Seed Data

    private func seedHiddenTag(db: OpaquePointer) throws {
        // Insert the "hidden" tag as a built-in tag
        let sql = "INSERT OR IGNORE INTO tag (name) VALUES ('hidden');"
        try execute(db: db, sql: sql)
        Log.debug("✓ Seeded 'hidden' tag")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 3, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
