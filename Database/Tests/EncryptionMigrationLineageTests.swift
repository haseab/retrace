import Foundation
import XCTest
import SQLCipher
@testable import Database

final class EncryptionMigrationLineageTests: XCTestCase {
    func testFreshDatabaseGetsMainSchemaAndEncryptionIdentity() async throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try await MigrationRunner(db: db).runMigrations()
        try assertReconciledSchema(db)
    }

    func testUpgradeFromEncryptionBranchV16BackfillsMainsV16Indexes() async throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try await createHistoryThroughV15(db)
        // Exact schema/version collision from the old encryption branch.
        try execute(db, """
            CREATE TABLE database_identity (
                singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
                library_id TEXT NOT NULL, shard_id TEXT NOT NULL, generation_id TEXT NOT NULL,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            );
            INSERT INTO database_identity VALUES(1,'existing-library','existing-vault','existing-generation',1,1);
            INSERT INTO schema_migrations(version) VALUES(16);
            """)
        try await MigrationRunner(db: db).runMigrations()
        try assertReconciledSchema(db)
        XCTAssertEqual(try text(db, "SELECT library_id FROM database_identity"), "existing-library")
        XCTAssertEqual(try text(db, "SELECT shard_id FROM database_identity"), "existing-vault")
        XCTAssertEqual(try text(db, "SELECT generation_id FROM database_identity"), "existing-generation")
        // Reopening/upgrading a second time is harmless.
        try await MigrationRunner(db: db).runMigrations()
        try assertReconciledSchema(db)
    }

    func testUpgradeFromMainV20PreservesFramesAndAddsIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("history.db").path
        let key = Data(repeating: 61, count: 32)
        let db = try openDatabase(path: path)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        try DatabaseManager.applyRetraceSQLCipherSettings(key, to: db)
        try await createHistoryThroughV15(db)
        for migration: any Migration in [V16_ProcessingQueueFrameIDIndex(), V17_FrameCaptureTrigger(), V18_DailyMetricsRecencyIndex(), V19_FrameEncodedAt(), V20_PartialProcessingStatusIndex()] {
            try await migration.migrate(db: db)
            try execute(db, "INSERT INTO schema_migrations(version) VALUES(\(migration.version));")
        }
        try execute(db, "UPDATE frame SET capture_trigger='window', encodedAt=123 WHERE imageFileName='history-canary';")
        try await MigrationRunner(db: db).runMigrations()
        try assertReconciledSchema(db)
        XCTAssertEqual(try text(db, "SELECT capture_trigger FROM frame WHERE imageFileName='history-canary'"), "window")
        XCTAssertEqual(try text(db, "SELECT encodedAt FROM frame WHERE imageFileName='history-canary'"), "123")
        try execute(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        try DatabaseManager.verifyDatabaseAccess(at: path, keyData: key)
        XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self).contains("history-canary"))
    }

    private func createHistoryThroughV15(_ db: OpaquePointer) async throws {
        try execute(db, Schema.createSchemaMigrationsTable)
        let migrations: [any Migration] = [V1_InitialSchema(), V2_UnfinalisedVideoTracking(), V3_TagSystem(), V4_DailyMetrics(), V5_FTSUnicode61(), V6_FrameProcessedAt(), V7_FrameRedactionReason(), V8_SegmentComments(), V9_SegmentCommentFrameAnchor(), V10_SegmentCommentSearchIndex(), V11_SegmentCommentLinkCompositeIndex(), V12_FrameMetadata(), V13_RemoveInPageURLRects(), V14_DBStorageSnapshot(), V15_NodeRedactionFlag()]
        for migration in migrations {
            try await migration.migrate(db: db)
            try execute(db, "INSERT INTO schema_migrations(version) VALUES(\(migration.version));")
        }
        try execute(db, "INSERT INTO frame(createdAt,imageFileName) VALUES(1,'history-canary');")
    }

    private func assertReconciledSchema(_ db: OpaquePointer) throws {
        XCTAssertEqual(try text(db, "SELECT MAX(version) FROM schema_migrations"), "21")
        XCTAssertEqual(try text(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='database_identity'"), "1")
        XCTAssertEqual(try text(db, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='idx_processing_queue_frameid'"), "1")
        XCTAssertEqual(try text(db, "SELECT count(*) FROM pragma_table_info('frame') WHERE name IN ('capture_trigger','encodedAt')"), "2")
        let partial = try text(db, "SELECT sql FROM sqlite_master WHERE name='idx_frame_processing_status'")
        XCTAssertTrue(partial.contains("WHERE processingStatus != 2"))
        // Existing history survives either source lineage.
        if try text(db, "SELECT count(*) FROM frame") != "0" {
            XCTAssertEqual(try text(db, "SELECT imageFileName FROM frame LIMIT 1"), "history-canary")
        }
    }

    private func openDatabase(path: String = ":memory:") throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: 1) }
        return db
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func text(_ db: OpaquePointer, _ sql: String) throws -> String {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
    }
}
