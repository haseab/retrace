import Foundation
import SQLCipher
import Shared

/// V11 Migration: add composite index to accelerate comment-existence predicates.
struct V11_SegmentCommentLinkCompositeIndex: Migration {
    let version = 11

    func migrate(db: OpaquePointer) async throws {
        Log.info("⚡ Adding composite index for segment comment links...", category: .database)

        try execute(
            db: db,
            sql: """
                CREATE INDEX IF NOT EXISTS index_segment_comment_link_on_segmentid_commentid
                ON segment_comment_link(segmentId, commentId);
                """
        )

        Log.info("✅ V11 migration completed: composite comment link index ready", category: .database)
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
