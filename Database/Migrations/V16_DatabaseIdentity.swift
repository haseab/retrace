import Foundation
import SQLCipher
import Shared

/// V16 Migration: Reconciles the divergent V15 histories by ensuring both the
/// protected OCR rewrite schema and database identity metadata exist.
struct V16_DatabaseIdentity: Migration {
    let version = 16

    func migrate(db: OpaquePointer) async throws {
        Log.info("🗄️ Reconciling forked V15 migrations...", category: .database)

        try MigrationRunner.executeStatements(
            db: db,
            statements: [
                """
                CREATE TABLE IF NOT EXISTS database_identity (
                    singleton_id    INTEGER PRIMARY KEY CHECK (singleton_id = 1),
                    library_id      TEXT NOT NULL,
                    shard_id        TEXT NOT NULL,
                    generation_id   TEXT NOT NULL,
                    created_at      INTEGER NOT NULL,
                    updated_at      INTEGER NOT NULL
                );
                """
            ]
        )

        // Both branches previously used version 15 for different schema work.
        // Re-run the protected-text migration idempotently so either history converges.
        try await V15_NodeRedactionFlag().migrate(db: db)

        Log.info(
            "✅ V16 migration completed: database identity and protected OCR schema verified",
            category: .database
        )
    }
}
