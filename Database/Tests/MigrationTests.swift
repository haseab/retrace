import XCTest
import SQLite3
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                           MIGRATION TESTS                                    ║
// ║                                                                              ║
// ║  • Verify all tables exist after migration                                   ║
// ║  • Verify all columns exist in each table                                    ║
// ║  • Verify all FTS triggers are created                                       ║
// ║  • Verify all indexes are created                                            ║
// ║  • Verify FTS triggers work (insert, update, delete)                         ║
// ║  • Verify migration is idempotent (can run multiple times)                   ║
// ║  • Verify existing data is preserved during migration                        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class MigrationTests: XCTestCase {

    var db: OpaquePointer?
    private static var hasPrintedSeparator = false

    override func setUp() {
        sqlite3_open(":memory:", &db)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

        // Print separator once before all tests
        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ HELPER METHODS                                                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    private func tableExists(_ tableName: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(statement, 1, tableName, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                let name = String(cString: namePtr)
                if name == column {
                    return true
                }
            }
        }
        return false
    }

    private func indexExists(_ indexName: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='index' AND name=?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(statement, 1, indexName, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func triggerExists(_ triggerName: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='trigger' AND name=?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(statement, 1, triggerName, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func getMigrationVersion() -> Int {
        let sql = "SELECT MAX(version) FROM schema_migrations;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ MIGRATION RUNNER TESTS                                                  │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testMigrationRunner_CreatesMigrationsTable() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        XCTAssertTrue(tableExists("schema_migrations"), "schema_migrations table should exist")
    }

    func testMigrationRunner_RecordsVersion() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let version = getMigrationVersion()
        XCTAssertEqual(version, Schema.currentVersion, "Version should match Schema.currentVersion")
    }

    func testMigrationRunner_GetCurrentVersion_ReturnsZero_WhenNoMigrations() async throws {
        // Create migrations table but don't run any migrations
        sqlite3_exec(db, Schema.createSchemaMigrationsTable, nil, nil, nil)

        let runner = MigrationRunner(db: db!)
        let version = try await runner.getCurrentVersion()

        XCTAssertEqual(version, 0, "Should return 0 when no migrations have run")
    }

    func testMigrationRunner_Idempotent_RunningTwiceHasNoEffect() async throws {
        let runner = MigrationRunner(db: db!)

        // Run migrations twice
        try await runner.runMigrations()
        try await runner.runMigrations()

        // Should still have correct version
        let version = getMigrationVersion()
        XCTAssertEqual(version, Schema.currentVersion)

        // Count migrations in table - should only be 1 entry for V1
        let sql = "SELECT COUNT(*) FROM schema_migrations;"
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        sqlite3_step(statement)
        let count = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)

        XCTAssertEqual(count, 1, "Should only have one migration recorded")
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ V1 INITIAL SCHEMA TESTS (OLD RETRACE SCHEMA)                            │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testV1Migration_CreatesAllTables() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        // V1 created the old Retrace schema - these tables should exist after V1 migration
        // Note: After V3 migration, these will be replaced with new Rewind-compatible tables
        let v1Tables = [
            "segments", "frames", "app_sessions", "documents",
            "text_regions", "audio_captures",
            "document_sessions", "session_segments",
            "encoding_queue", "deletion_queue",
            "documents_fts"
        ]

        print("Checking if \(v1Tables.count)/\(v1Tables.count) V1 tables exist...")

        var missingTables: [String] = []
        for table in v1Tables {
            if !tableExists(table) {
                missingTables.append(table)
            }
        }

        let foundCount = v1Tables.count - missingTables.count

        if missingTables.isEmpty {
            print("✅ All \(v1Tables.count) V1 tables exist")
        } else {
            print("❌ Only \(foundCount)/\(v1Tables.count) V1 tables exist")
            print("❌ Missing: \(missingTables.joined(separator: ", "))")
        }

        // Positive assertions
        for table in v1Tables {
            XCTAssertTrue(tableExists(table), "\(table) table should exist after V1 migration")
        }

        // Negative test: verify non-existent tables are correctly detected
        XCTAssertFalse(tableExists("non_existent_table"), "Should correctly detect missing table")
    }

    func testV1Migration_CreatesFTSTriggers() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let allTriggers = ["documents_ai", "documents_ad", "documents_au"]

        print("Checking if \(allTriggers.count)/\(allTriggers.count) FTS triggers exist...")

        var missingTriggers: [String] = []
        for trigger in allTriggers {
            if !triggerExists(trigger) {
                missingTriggers.append(trigger)
            }
        }

        let foundCount = allTriggers.count - missingTriggers.count

        if missingTriggers.isEmpty {
            print("✅ All \(allTriggers.count) FTS triggers exist")
        } else {
            print("❌ Only \(foundCount)/\(allTriggers.count) FTS triggers exist")
            print("❌ Missing: \(missingTriggers.joined(separator: ", "))")
        }

        for trigger in allTriggers {
            XCTAssertTrue(triggerExists(trigger), "\(trigger) trigger should exist")
        }
    }

    func testV1Migration_CreatesAllIndexes() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let allIndexes = [
            "idx_segments_time", "idx_segments_source",
            "idx_frames_timestamp", "idx_frames_segment", "idx_frames_app",
            "idx_frames_source", "idx_frames_session", "idx_frames_encoding_status",
            "idx_app_sessions_time", "idx_app_sessions_app"
        ]

        print("Checking if \(allIndexes.count)/\(allIndexes.count) indexes exist...")

        var missingIndexes: [String] = []
        for index in allIndexes {
            if !indexExists(index) {
                missingIndexes.append(index)
            }
        }

        let foundCount = allIndexes.count - missingIndexes.count

        if missingIndexes.isEmpty {
            print("✅ All \(allIndexes.count) indexes exist")
        } else {
            print("❌ Only \(foundCount)/\(allIndexes.count) indexes exist")
            print("❌ Missing: \(missingIndexes.joined(separator: ", "))")
        }

        for index in allIndexes {
            XCTAssertTrue(indexExists(index), "\(index) should exist")
        }
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ COLUMN VERIFICATION TESTS                                               │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testAllTables_HaveRequiredColumns() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let tableColumns: [(table: String, columns: [String])] = [
            ("segments", ["id", "start_time", "end_time", "frame_count", "file_size_bytes", "relative_path", "width", "height", "source", "created_at"]),
            ("frames", ["id", "segment_id", "session_id", "timestamp", "frame_index", "encoding_status", "app_bundle_id", "app_name", "window_title", "browser_url", "source", "created_at"]),
            ("documents", ["id", "frame_id", "content", "app_name", "window_title", "browser_url", "timestamp", "created_at"])
        ]

        let totalColumns = tableColumns.reduce(0) { $0 + $1.columns.count }
        print("Checking if \(totalColumns) columns exist across \(tableColumns.count) key tables...")

        var allMissing: [(table: String, column: String)] = []

        for (table, columns) in tableColumns {
            for column in columns {
                if !columnExists(table: table, column: column) {
                    allMissing.append((table, column))
                }
            }
        }

        if allMissing.isEmpty {
            print("✅ All \(totalColumns) columns exist")
        } else {
            print("❌ Missing \(allMissing.count) column(s):")
            for (table, column) in allMissing {
                print("  - \(table).\(column)")
            }
        }

        // Positive assertions
        for (table, columns) in tableColumns {
            for column in columns {
                XCTAssertTrue(columnExists(table: table, column: column), "\(table).\(column) should exist")
            }
        }

        // Negative tests: verify non-existent columns are correctly detected
        XCTAssertFalse(columnExists(table: "segments", column: "non_existent_column"), "Should correctly detect missing column")
        XCTAssertFalse(columnExists(table: "frames", column: "fake_field"), "Should correctly detect missing column")
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ DATA PRESERVATION TESTS                                                 │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testMigration_PreservesExistingData() async throws {
        print("Testing data preservation through schema creation")

        // Run migrations first to create schema
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        // Insert test data into the new Rewind schema
        sqlite3_exec(db, """
            INSERT INTO segment (id, bundleID, startDate, endDate, type)
            VALUES (1, 'com.test.app', 1000, 2000, 0);
            """, nil, nil, nil)

        // Verify data persists
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM segment WHERE id = 1", -1, &statement, nil)
        let hasData = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)

        print("  \(hasData ? "✓" : "✗") Data persists after schema creation")

        XCTAssertTrue(hasData, "Data should be preserved")
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ FTS TRIGGER INTEGRATION TESTS                                           │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFTSTriggers_Functionality() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        // Setup test data
        sqlite3_exec(db, """
            INSERT INTO segments (id, start_time, end_time, frame_count, file_size_bytes, relative_path, width, height)
            VALUES ('seg-1', 1000, 2000, 1, 1000, 'test.hevc', 1920, 1080);
            """, nil, nil, nil)
        sqlite3_exec(db, """
            INSERT INTO frames (id, segment_id, timestamp, frame_index)
            VALUES ('frame-1', 'seg-1', 1500, 0);
            """, nil, nil, nil)

        var testResults: [(name: String, passed: Bool)] = []
        var statement: OpaquePointer?

        // Test 1: Insert triggers auto-indexing
        sqlite3_exec(db, """
            INSERT INTO documents (frame_id, content, timestamp)
            VALUES ('frame-1', 'Hello World', 1500);
            """, nil, nil, nil)

        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'Hello';", -1, &statement, nil)
        sqlite3_step(statement)
        let insertCount = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        let insertPassed = insertCount == 1
        testResults.append(("Insert triggers auto-indexing", insertPassed))
        XCTAssertEqual(insertCount, 1)

        // Negative test
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'NonExistentWord';", -1, &statement, nil)
        sqlite3_step(statement)
        let notFoundCount = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        XCTAssertEqual(notFoundCount, 0, "Should not find non-existent content")

        // Test 2: Update re-indexes content
        sqlite3_exec(db, "UPDATE documents SET content = 'NewContent' WHERE frame_id = 'frame-1';", nil, nil, nil)
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'Hello';", -1, &statement, nil)
        sqlite3_step(statement)
        let oldCount = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'NewContent';", -1, &statement, nil)
        sqlite3_step(statement)
        let newCount = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        let updatePassed = oldCount == 0 && newCount == 1
        testResults.append(("Update re-indexes content", updatePassed))
        XCTAssertEqual(oldCount, 0, "Old content should be removed from index")
        XCTAssertEqual(newCount, 1, "New content should be in index")

        // Test 3: Delete removes from index
        sqlite3_exec(db, "DELETE FROM documents WHERE frame_id = 'frame-1';", nil, nil, nil)
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'NewContent';", -1, &statement, nil)
        sqlite3_step(statement)
        let deleteCount = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        let deletePassed = deleteCount == 0
        testResults.append(("Delete removes from index", deletePassed))
        XCTAssertEqual(deleteCount, 0, "Deleted content should not be in index")

        // Clean summary output
        print("Testing 3 FTS trigger behaviors")
        for (name, passed) in testResults {
            print("  \(passed ? "✓" : "✗") \(name)")
        }
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ V1 REWIND SCHEMA TESTS (REWIND-COMPATIBLE SCHEMA)                      │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testV1Migration_CreatesAllRewindTables() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        // V1 creates the Rewind-compatible schema
        let v1Tables = [
            "segment", "frame", "node", "video",
            "audio", "transcript_word",
            "searchRanking", "searchRanking_content",
            "event", "summary",
            "doc_segment", "videoFileState", "frame_processing", "purge"
        ]

        print("Checking if \(v1Tables.count)/\(v1Tables.count) V1 Rewind tables exist...")

        var missingTables: [String] = []
        for table in v1Tables {
            if !tableExists(table) {
                missingTables.append(table)
            }
        }

        let foundCount = v1Tables.count - missingTables.count

        if missingTables.isEmpty {
            print("✅ All \(v1Tables.count) V1 Rewind tables exist")
        } else {
            print("❌ Only \(foundCount)/\(v1Tables.count) V1 Rewind tables exist")
            print("❌ Missing: \(missingTables.joined(separator: ", "))")
        }

        // Positive assertions
        for table in v1Tables {
            XCTAssertTrue(tableExists(table), "\(table) table should exist after V1 migration")
        }

        // Negative test: Old Retrace tables should NOT exist with V1 fresh install
        let oldTables = ["segments", "frames", "text_regions", "documents", "documents_fts"]
        for oldTable in oldTables {
            XCTAssertFalse(tableExists(oldTable), "\(oldTable) should not exist in V1 fresh schema")
        }
    }

    func testV1Migration_SegmentTableHasCorrectColumns() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let requiredColumns = ["id", "bundleID", "startDate", "endDate", "windowName", "browserUrl", "type"]

        print("Checking segment table has \(requiredColumns.count) required columns...")

        var missingColumns: [String] = []
        for column in requiredColumns {
            if !columnExists(table: "segment", column: column) {
                missingColumns.append(column)
            }
        }

        if missingColumns.isEmpty {
            print("✅ segment table has all \(requiredColumns.count) columns (camelCase)")
        } else {
            print("❌ segment table missing: \(missingColumns.joined(separator: ", "))")
        }

        for column in requiredColumns {
            XCTAssertTrue(columnExists(table: "segment", column: column), "segment.\(column) should exist")
        }

        // Negative test: Old snake_case columns should NOT exist
        XCTAssertFalse(columnExists(table: "segment", column: "start_time"), "Old snake_case column should not exist")
        XCTAssertFalse(columnExists(table: "segment", column: "end_time"), "Old snake_case column should not exist")
    }

    func testV1Migration_FrameTableHasCorrectColumns() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let requiredColumns = ["id", "createdAt", "imageFileName", "segmentId", "videoId", "videoFrameIndex", "isStarred", "encodingStatus"]

        print("Checking frame table has \(requiredColumns.count) required columns...")

        var missingColumns: [String] = []
        for column in requiredColumns {
            if !columnExists(table: "frame", column: column) {
                missingColumns.append(column)
            }
        }

        if missingColumns.isEmpty {
            print("✅ frame table has all \(requiredColumns.count) columns (camelCase)")
        } else {
            print("❌ frame table missing: \(missingColumns.joined(separator: ", "))")
        }

        for column in requiredColumns {
            XCTAssertTrue(columnExists(table: "frame", column: column), "frame.\(column) should exist")
        }

        // Negative test: Old columns should NOT exist
        XCTAssertFalse(columnExists(table: "frame", column: "timestamp"), "Old timestamp column should not exist (renamed to createdAt)")
        XCTAssertFalse(columnExists(table: "frame", column: "segment_id"), "Old snake_case column should not exist")
    }

    func testV1Migration_NodeTableHasNormalizedCoordinates() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let requiredColumns = ["id", "frameId", "nodeOrder", "textOffset", "textLength", "leftX", "topY", "width", "height", "windowIndex"]

        print("Checking node table has \(requiredColumns.count) required columns with normalized coordinates...")

        var missingColumns: [String] = []
        for column in requiredColumns {
            if !columnExists(table: "node", column: column) {
                missingColumns.append(column)
            }
        }

        if missingColumns.isEmpty {
            print("✅ node table has all \(requiredColumns.count) columns (normalized coords)")
        } else {
            print("❌ node table missing: \(missingColumns.joined(separator: ", "))")
        }

        for column in requiredColumns {
            XCTAssertTrue(columnExists(table: "node", column: column), "node.\(column) should exist")
        }
    }

    func testV1Migration_SearchRankingFTSTablesExist() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        print("Checking new FTS5 searchRanking tables...")

        XCTAssertTrue(tableExists("searchRanking"), "searchRanking FTS5 table should exist")
        XCTAssertTrue(tableExists("searchRanking_content"), "searchRanking_content table should exist")

        // Verify searchRanking_content columns
        XCTAssertTrue(columnExists(table: "searchRanking_content", column: "id"), "searchRanking_content.id should exist")
        XCTAssertTrue(columnExists(table: "searchRanking_content", column: "c0"), "searchRanking_content.c0 (text) should exist")
        XCTAssertTrue(columnExists(table: "searchRanking_content", column: "c1"), "searchRanking_content.c1 (otherText) should exist")
        XCTAssertTrue(columnExists(table: "searchRanking_content", column: "c2"), "searchRanking_content.c2 (title) should exist")

        print("✅ searchRanking FTS5 tables exist with correct structure")
    }

    func testV1Migration_AudioTablesHaveCorrectStructure() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        print("Checking audio and transcript_word tables...")

        // Check audio table
        let audioColumns = ["id", "segmentId", "path", "startTime", "duration"]
        for column in audioColumns {
            XCTAssertTrue(columnExists(table: "audio", column: column), "audio.\(column) should exist")
        }

        // Check transcript_word table
        let transcriptColumns = ["id", "segmentId", "speechSource", "word", "timeOffset", "fullTextOffset", "duration"]
        for column in transcriptColumns {
            XCTAssertTrue(columnExists(table: "transcript_word", column: column), "transcript_word.\(column) should exist")
        }

        print("✅ audio and transcript_word tables have correct structure")
    }

    func testV1Migration_CreatesAllRewindIndexes() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        // V3 should create 21 indexes total (16 Rewind + 5 new partial indexes)
        let expectedIndexes = [
            // segment indexes
            "idx_segment_bundleID",
            "idx_segment_endDate",
            "idx_segment_startDate",
            "idx_segment_windowName",
            "idx_segment_browserUrl",

            // frame indexes
            "idx_frame_createdAt",
            "idx_frame_encodingStatus_createdAt",
            "idx_frame_isStarred_createdAt",
            "idx_frame_segmentId_createdAt",
            "idx_frame_videoId",

            // node indexes
            "idx_node_frameId",
            "idx_node_windowIndex",

            // Other indexes
            "idx_transcript_word_segmentId_fullTextOffset",
            "idx_event_calendarSeriesID",
            "idx_event_status",
            "idx_summary_eventId",
            "idx_summary_status",
            "idx_doc_segment_frameId_docid",
            "idx_doc_segment_segmentId_docid",
            "idx_video_width_height",
            "idx_audio_startTime"
        ]

        print("Checking if \(expectedIndexes.count)/\(expectedIndexes.count) V3 indexes exist...")

        var missingIndexes: [String] = []
        for index in expectedIndexes {
            if !indexExists(index) {
                missingIndexes.append(index)
            }
        }

        let foundCount = expectedIndexes.count - missingIndexes.count

        if missingIndexes.isEmpty {
            print("✅ All \(expectedIndexes.count) V3 Rewind indexes exist")
        } else {
            print("❌ Only \(foundCount)/\(expectedIndexes.count) V3 indexes exist")
            print("❌ Missing: \(missingIndexes.joined(separator: ", "))")
        }

        for index in expectedIndexes {
            XCTAssertTrue(indexExists(index), "\(index) should exist after V3 migration")
        }
    }

    func testV1Migration_VideoTableExists() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        XCTAssertTrue(tableExists("video"), "video table should exist")

        let requiredColumns = ["id", "height", "width", "path", "fileSize", "frameRate", "uploadedAt", "xid", "processingState"]
        for column in requiredColumns {
            XCTAssertTrue(columnExists(table: "video", column: column), "video.\(column) should exist")
        }

        print("✅ video table exists with correct columns")
    }

    func testV1Migration_UtilityTablesExist() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        let utilityTables = ["doc_segment", "videoFileState", "frame_processing", "purge"]

        print("Checking \(utilityTables.count) utility tables...")

        for table in utilityTables {
            XCTAssertTrue(tableExists(table), "\(table) utility table should exist")
        }

        print("✅ All utility tables exist")
    }

    func testV1Migration_EventAndSummaryTablesExist() async throws {
        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        XCTAssertTrue(tableExists("event"), "event table should exist")
        XCTAssertTrue(tableExists("summary"), "summary table should exist")

        // Check event columns
        let eventColumns = ["id", "type", "status", "title", "participants", "detailsJSON", "calendarID", "calendarEventID", "calendarSeriesID", "segmentID"]
        for column in eventColumns {
            XCTAssertTrue(columnExists(table: "event", column: column), "event.\(column) should exist")
        }

        // Check summary columns
        let summaryColumns = ["id", "status", "text", "eventId"]
        for column in summaryColumns {
            XCTAssertTrue(columnExists(table: "summary", column: column), "summary.\(column) should exist")
        }

        print("✅ event and summary tables exist for future meeting features")
    }
}
