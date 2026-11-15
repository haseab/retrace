import Foundation
import SQLCipher
import Shared

/// Capture evidence has its own column: in-page URL metadata can be replaced/cleared independently.
struct V21_WindowTitleEvidence: Migration {
    let version = 21
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "ALTER TABLE frame ADD COLUMN captureWindowTitleEvidence TEXT;"
        ])
        Log.info("V21: added optional capture window-title evidence; legacy frames unchanged", category: .database)
    }
}
