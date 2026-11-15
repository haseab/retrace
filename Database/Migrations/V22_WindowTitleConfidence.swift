import Foundation
import SQLCipher
import Shared

/// Validation belongs to individual frames, never to their shared app/window segment.
struct V22_WindowTitleConfidence: Migration {
    let version = 22
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "ALTER TABLE frame ADD COLUMN resolvedWindowTitle TEXT;",
            "ALTER TABLE frame ADD COLUMN windowTitleConfidence INTEGER NOT NULL DEFAULT 0 CHECK(typeof(windowTitleConfidence) = 'integer' AND windowTitleConfidence BETWEEN 0 AND 10);",
            "ALTER TABLE frame ADD COLUMN windowTitleValidationOutcome TEXT;"
        ])
        Log.info("V22: added per-frame title confidence; historical confidence remains unknown", category: .database)
    }
}
