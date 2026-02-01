import Foundation
import SQLCipher
import Shared

/// V5 Migration: Rebuild FTS5 searchRanking table with unicode61 tokenizer
/// Changes from porter (stemming) to unicode61 (exact matching, better multilingual support)
struct V5_FTSUnicode61: Migration {
    let version = 5

    func migrate(db: OpaquePointer) async throws {
        Log.info("🔤 Rebuilding FTS5 table with unicode61 tokenizer...", category: .database)

        try rebuildFTSTable(db: db)

        Log.info("✅ FTS5 unicode61 migration completed successfully", category: .database)
    }

    // MARK: - FTS Rebuild

    private func rebuildFTSTable(db: OpaquePointer) throws {
        // Clean up any failed previous attempts
        try execute(db: db, sql: "DROP TABLE IF EXISTS searchRanking_new;")

        // Create new FTS5 table with unicode61 tokenizer
        try execute(db: db, sql: """
            CREATE VIRTUAL TABLE searchRanking_new USING fts5(
                text,
                otherText,
                title,
                tokenize = 'unicode61'
            );
            """)
        Log.debug("✓ Created searchRanking_new with unicode61 tokenizer")

        // Copy data from old table (using stable virtual table API, not shadow tables)
        try execute(db: db, sql: """
            INSERT INTO searchRanking_new(rowid, text, otherText, title)
            SELECT rowid, text, otherText, title FROM searchRanking;
            """)
        Log.debug("✓ Copied data to new FTS table")

        // Rename old table as backup
        try execute(db: db, sql: "ALTER TABLE searchRanking RENAME TO searchRanking_old;")
        Log.debug("✓ Renamed old table to searchRanking_old")

        // Swap in the new table
        try execute(db: db, sql: "ALTER TABLE searchRanking_new RENAME TO searchRanking;")
        Log.debug("✓ Renamed new table to searchRanking")

        // Drop the old table (and its shadow tables)
        try execute(db: db, sql: "DROP TABLE IF EXISTS searchRanking_old;")
        Log.debug("✓ Dropped old searchRanking_old table")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 5, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
