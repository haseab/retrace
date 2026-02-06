import Foundation
import SQLCipher
import Shared

/// V6 Migration: Add processedAt column to frame table
/// Tracks when OCR processing completed for each frame
struct V6_FrameProcessedAt: Migration {
    let version = 6

    func migrate(db: OpaquePointer) async throws {
        Log.info("📊 Adding processedAt column to frame table...", category: .database)

        // Add processedAt column (nullable - existing frames will have NULL)
        try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN processedAt INTEGER;")
        Log.debug("✓ Added processedAt column to frame table")

        // Create index for efficient querying by processedAt
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_frame_processed_at ON frame(processedAt);")
        Log.debug("✓ Created index on processedAt")

        // Backfill: For existing completed frames (processingStatus = 2),
        // set processedAt to createdAt as an approximation
        try execute(db: db, sql: """
            UPDATE frame SET processedAt = createdAt WHERE processingStatus = 2 AND processedAt IS NULL;
            """)
        Log.debug("✓ Backfilled processedAt for existing completed frames")

        Log.info("✅ V6 migration completed: frame.processedAt column added", category: .database)
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 6, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
