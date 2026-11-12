import Foundation
import SQLCipher
import Shared

/// V21 Migration: Add content-addressed storage for accessibility tree snapshots.
///
/// - `ax_node`: one row per distinct element subtree, keyed by a SHA-256 of the
///   element's attributes and its children's hashes. Identical subtrees captured in
///   different frames share one row.
/// - `ax_node_child`: ordered parent → child edges.
/// - `frame_ax_snapshot`: one row per frame that has a snapshot, pointing at its root.
///   Deleted with its frame; nodes no snapshot reaches are removed by
///   `AXSnapshotQueries.purgeUnreferencedNodes`.
struct V21_AccessibilitySnapshots: Migration {
    let version = 21

    func migrate(db: OpaquePointer) async throws {
        Log.info("🌳 Creating accessibility snapshot tables...", category: .database)

        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS ax_node (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                hash    BLOB NOT NULL UNIQUE,
                role    TEXT NOT NULL,
                subrole TEXT,
                title   TEXT,
                value   TEXT,
                label   TEXT,
                x       REAL,
                y       REAL,
                width   REAL,
                height  REAL
            );
            """)

        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS ax_node_child (
                parentId INTEGER NOT NULL,
                position INTEGER NOT NULL,
                childId  INTEGER NOT NULL,
                PRIMARY KEY (parentId, position)
            ) WITHOUT ROWID;
            """)

        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS frame_ax_snapshot (
                frameId     INTEGER PRIMARY KEY,
                rootNodeId  INTEGER NOT NULL,
                bundleID    TEXT,
                processID   INTEGER NOT NULL,
                nodeCount   INTEGER NOT NULL,
                isTruncated INTEGER NOT NULL DEFAULT 0,
                walkMs      INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE
            );
            """)

        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_frame_ax_snapshot_root
            ON frame_ax_snapshot(rootNodeId);
            """)

        Log.info("✅ V21 migration completed: accessibility snapshot tables created", category: .database)
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
