import Foundation
import SQLCipher
import Shared

/// Migration V2: Add frameCount column to video table
/// Enables tracking of unfinalised videos by resolution for multi-resolution video writing
/// (different resolutions go to different video files, like Rewind)
/// Note: We use the existing processingState column (0 = completed, 1 = in progress) instead of adding isFinalized
struct V2_UnfinalisedVideoTracking: Migration {
    let version = 2

    func migrate(db: OpaquePointer) async throws {
        Log.info("📦 Running V2 migration: Adding unfinalised video tracking...", category: .database)

        // Add frameCount column to track how many frames have been written
        // Default to 150 for existing videos (assumed finalized)
        try execute(db: db, sql: """
            ALTER TABLE video ADD COLUMN frameCount INTEGER NOT NULL DEFAULT 150;
            """)
        Log.debug("✓ Added frameCount column to video table")

        // Mark all existing videos as completed (processingState = 0)
        // This ensures old videos without explicit state are treated as finalized
        try execute(db: db, sql: """
            UPDATE video SET processingState = 0 WHERE processingState IS NULL OR processingState != 0;
            """)
        Log.debug("✓ Ensured all existing videos have processingState = 0 (completed)")

        // Create index for efficient lookup of unfinalised videos by resolution
        // processingState = 1 means video is still being written to
        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS index_video_on_unfinalized_resolution
            ON video(width, height, processingState) WHERE processingState = 1;
            """)
        Log.debug("✓ Created index for unfinalised video lookup by resolution")

        Log.info("✅ V2 migration completed successfully", category: .database)
    }

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 2, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
