import Foundation
import SQLCipher
import Shared

/// V16 Migration: add the hot-path indexes introduced during startup/search perf work
/// before this schema ships anywhere outside local development.
struct V16_ProcessingQueueFrameIDIndex: Migration {
    let version = 16

    func migrate(db: OpaquePointer) async throws {
        Log.info("🔎 Verifying V16 hot-path indexes...", category: .database)

        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_processing_queue_frameid ON processing_queue(frameId);"
        )
        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS idx_frame_rewritten_at
                ON frame(rewrittenAt)
                WHERE rewrittenAt IS NOT NULL;
                """
        )
        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS index_doc_segment_on_docid_frameid
                ON doc_segment(docid, frameId);
                """
        )

        Log.info(
            "✅ V16 migration completed: processing_queue frameId, frame.rewrittenAt, and doc_segment(docid, frameId) indexes verified",
            category: .database
        )
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
