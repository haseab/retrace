import Foundation
import SQLCipher
import Shared

/// Retain index entries only for frames whose OCR status is not completed.
/// MigrationRunner wraps the replacement and version record in one transaction.
struct V20_PartialProcessingStatusIndex: Migration {
    let version = 20

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "DROP INDEX IF EXISTS idx_frame_processing_status;",
            """
                CREATE INDEX idx_frame_processing_status ON frame(processingStatus)
                WHERE processingStatus != 2;
                """
        ])
        Log.info("V20: processing-status index now excludes OCR-completed frames", category: .database)
    }
}
