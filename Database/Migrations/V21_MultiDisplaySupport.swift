import Foundation
import SQLCipher
import Shared

/// V21 Migration: Add multi-display support and persistent display metadata.
/// Adds displayID/isFocused columns and indexes, plus display metadata tables.
struct V21_MultiDisplaySupport: Migration {
    let version = 21

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding multi-display support columns...", category: .database)

        // Add displayID to frame table (which physical display produced this frame)
        // DEFAULT 0 so all legacy single-display frames get a neutral value
        if try !hasColumn(db: db, table: "frame", column: "displayID") {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN displayID INTEGER NOT NULL DEFAULT 0;")
        }
        Log.debug("Added displayID column to frame table")

        // Add isFocused to frame table (was user looking at this display when frame was captured?)
        // DEFAULT 1 so all legacy frames are treated as focused (backward compatible)
        if try !hasColumn(db: db, table: "frame", column: "isFocused") {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN isFocused INTEGER NOT NULL DEFAULT 1;")
        }
        Log.debug("Added isFocused column to frame table")

        // Add displayID to video table (prevents resuming wrong display's video when two displays share resolution)
        if try !hasColumn(db: db, table: "video", column: "displayID") {
            try execute(db: db, sql: "ALTER TABLE video ADD COLUMN displayID INTEGER NOT NULL DEFAULT 0;")
        }
        Log.debug("Added displayID column to video table")

        // Index for efficient per-display time range queries
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_frame_displayid_createdat ON frame(displayID, createdAt);")
        Log.debug("Created index idx_frame_displayid_createdat")

        // Index for filtering focused vs secondary display frames
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_frame_isfocused_createdat ON frame(isFocused, createdAt);")
        Log.debug("Created index idx_frame_isfocused_createdat")

        // Partial index for unfinalised video lookup by display and resolution
        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_video_unfinalized_display ON video(displayID, width, height, processingState)
            WHERE processingState = 1;
            """)
        Log.debug("Created index idx_video_unfinalized_display")

        // Persist display labels for stable naming across app sessions.
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS display (
                displayID INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                lastSeenAt INTEGER NOT NULL
            );
            """)
        Log.debug("Created table display")

        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_display_lastSeenAt ON display(lastSeenAt DESC);")
        Log.debug("Created index idx_display_lastSeenAt")

        // Track connected/disconnected time ranges for each display.
        // Enables accurate historical checks for whether a display was present at a timestamp.
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS display_session (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                displayID INTEGER NOT NULL,
                connectedAt INTEGER NOT NULL,
                disconnectedAt INTEGER,
                createdAt INTEGER DEFAULT (strftime('%s', 'now') * 1000),
                CHECK(disconnectedAt IS NULL OR disconnectedAt >= connectedAt),
                FOREIGN KEY (displayID) REFERENCES display(displayID) ON DELETE CASCADE
            );
            """)
        Log.debug("Created table display_session")

        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_display_session_display_connected
            ON display_session(displayID, connectedAt DESC);
            """)
        Log.debug("Created index idx_display_session_display_connected")

        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_display_session_connected_disconnected
            ON display_session(connectedAt, disconnectedAt);
            """)
        Log.debug("Created index idx_display_session_connected_disconnected")

        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_display_session_active
            ON display_session(displayID)
            WHERE disconnectedAt IS NULL;
            """)
        Log.debug("Created index idx_display_session_active")

        // Enforce invariant: at most one open segment per display.
        try execute(db: db, sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS uniq_display_session_open
            ON display_session(displayID)
            WHERE disconnectedAt IS NULL;
            """)
        Log.debug("Created unique index uniq_display_session_open")

        Log.info("V21 migration completed: multi-display support + display metadata tables added", category: .database)
    }

    // MARK: - Helper

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
            throw DatabaseError.migrationFailed(version: 21, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
