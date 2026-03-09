import Foundation
import SQLCipher
import Shared

/// V13 Migration: drop persisted hyperlink rect columns and keep node-based mappings only.
struct V13_RemoveInPageURLRects: Migration {
    let version = 13

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧩 Upgrading in-page URL rows to node-only storage...", category: .database)
        try FrameQueries.ensureInPageURLSchema(db: db)
        Log.info("✅ V13 migration completed: in-page URL rows use node-only storage", category: .database)
    }
}
