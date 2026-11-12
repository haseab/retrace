import Foundation
import SQLCipher
import Shared

/// V20 Migration: Add the frame_window table.
///
/// Stores, for each frame, the windows that were on screen when it was captured, front
/// to back, in frame pixel coordinates. Processing uses it to group OCR text by window.
/// Rows are deleted with their frame.
struct V20_FrameWindowMap: Migration {
    let version = 20

    func migrate(db: OpaquePointer) async throws {
        Log.info("🪟 Creating frame_window table...", category: .database)

        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS frame_window (
                    frameId   INTEGER NOT NULL,
                    zOrder    INTEGER NOT NULL,
                    windowId  INTEGER NOT NULL,
                    bundleID  TEXT,
                    appName   TEXT,
                    title     TEXT,
                    x         REAL NOT NULL,
                    y         REAL NOT NULL,
                    width     REAL NOT NULL,
                    height    REAL NOT NULL,
                    layer     INTEGER NOT NULL DEFAULT 0,
                    isFocused INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (frameId, zOrder),
                    FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE
                ) WITHOUT ROWID;
                """
        )

        Log.info("✅ V20 migration completed: frame_window table created", category: .database)
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
