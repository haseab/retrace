import XCTest
import Foundation
import CoreGraphics
import Shared
import SQLCipher
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      DATABASE MANAGER TESTS                                  ║
// ║                                                                              ║
// ║  • Verify segment CRUD operations (insert, get, delete)                      ║
// ║  • Verify frame CRUD operations (insert, get, query by time/app)             ║
// ║  • Verify cascade deletes (deleting segment removes frames)                  ║
// ║  • Verify storage calculations (total bytes)                                 ║
// ║  • Verify statistics queries (frame count, oldest/newest dates)              ║
// ║  • Verify time-based queries and deletions                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class DatabaseManagerTests: XCTestCase {

    var database: DatabaseManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        print("[TEST DEBUG] setUp() started")
        // Use unique in-memory database name per test to avoid FTS5 pointer corruption
        // when multiple in-memory databases are created/destroyed in same process
        let uniqueDbPath = "file:memdb_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDbPath)
        print("[TEST DEBUG] DatabaseManager created with path: \(uniqueDbPath)")
        try await database.initialize()
        print("[TEST DEBUG] Database initialized")

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
        print("[TEST DEBUG] setUp() complete")
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ MIGRATION TEST                                                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testActualDatabaseMigration() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDatabaseMigrationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("retrace.db").path
        let db = DatabaseManager(databasePath: dbPath)

        try await db.initialize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        print("✅ Database migration completed successfully at: \(dbPath)")
        try await db.close()
    }

    func testDBStorageSnapshotMigrationCreatesExpectedColumns() async throws {
        let columnNames = try await tableColumnNames("db_storage_snapshot")

        XCTAssertEqual(
            columnNames,
            ["local_day", "db_bytes", "wal_bytes", "sampled_at"]
        )
    }

    func testReadConnectionPoolCloseRejectsQueuedCheckout() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceReadPoolCloseTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("retrace.db").path
        let fileDatabase = DatabaseManager(databasePath: dbPath)
        defer {
            Task {
                try? await fileDatabase.close()
            }
        }

        try await fileDatabase.initialize()

        let pool = SQLiteReadConnectionPool(
            label: "test_read_pool_close",
            maxConnections: 1,
            connectionFactory: {
                try SQLiteReadOnlyConnectionFactory.makeRetraceConnection(databasePath: dbPath)
            }
        )
        let firstLeaseStarted = DispatchSemaphore(value: 0)
        let releaseFirstLease = DispatchSemaphore(value: 0)
        let queuedCheckoutStarted = DispatchSemaphore(value: 0)

        let firstTask = Task.detached(priority: .userInitiated) {
            try await pool.withConnection(operation: "hold_first_connection") { _ in
                firstLeaseStarted.signal()
                _ = releaseFirstLease.wait(timeout: .now() + 2)
            }
        }

        XCTAssertEqual(firstLeaseStarted.wait(timeout: .now() + 1), .success)

        let queuedTask = Task.detached(priority: .userInitiated) {
            queuedCheckoutStarted.signal()
            try await pool.withConnection(operation: "queued_checkout") { _ in
                XCTFail("Queued checkout should not receive a connection after close begins")
            }
        }

        XCTAssertEqual(queuedCheckoutStarted.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(50), clock: .continuous)

        let closeTask = Task {
            await pool.close()
        }

        releaseFirstLease.signal()
        try await firstTask.value
        await closeTask.value

        do {
            try await queuedTask.value
            XCTFail("Expected queued checkout to fail once the pool closes")
        } catch DatabaseConnectionError.readPoolClosed {
            // Expected.
        } catch {
            XCTFail("Expected readPoolClosed, got \(error)")
        }
    }

    func testReadConnectionPoolInterruptsCancelledRunningQuery() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceReadPoolInterruptTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("retrace.db").path
        let fileDatabase = DatabaseManager(databasePath: dbPath)
        defer {
            Task {
                try? await fileDatabase.close()
            }
        }

        try await fileDatabase.initialize()

        let pool = fileDatabase.readConnectionPool
        let queryStarted = DispatchSemaphore(value: 0)

        let task = Task.detached(priority: .userInitiated) {
            try await pool.withConnection(operation: "interrupt_cancelled_query") { connection in
                guard let db = connection.getConnection() else {
                    throw DatabaseConnectionError.notConnected
                }

                let functionName = "test_slow_identity"
                let functionResult = sqlite3_create_function_v2(
                    db,
                    functionName,
                    1,
                    SQLITE_UTF8,
                    nil,
                    { context, argc, argv in
                        guard let context, argc == 1, let argv else { return }
                        usleep(1_000)
                        sqlite3_result_int64(context, sqlite3_value_int64(argv[0]))
                    },
                    nil,
                    nil,
                    nil
                )
                guard functionResult == SQLITE_OK else {
                    let message = String(cString: sqlite3_errmsg(db))
                    throw DatabaseConnectionError.connectionConfigurationFailed(error: message)
                }

                let sql = """
                WITH RECURSIVE cnt(x) AS (
                    VALUES(0)
                    UNION ALL
                    SELECT x + 1 FROM cnt WHERE x < 1000
                )
                SELECT \(functionName)(x) FROM cnt;
                """

                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    let message = String(cString: sqlite3_errmsg(db))
                    throw DatabaseConnectionError.statementPreparationFailed(sql: sql, error: message)
                }
                defer {
                    sqlite3_finalize(statement)
                }

                queryStarted.signal()

                while true {
                    let rc = sqlite3_step(statement)
                    switch rc {
                    case SQLITE_ROW:
                        continue
                    case SQLITE_DONE:
                        return
                    case SQLITE_INTERRUPT:
                        throw DatabaseConnectionError.executionFailed(sql: sql, error: "interrupted")
                    default:
                        let message = String(cString: sqlite3_errmsg(db))
                        throw DatabaseConnectionError.executionFailed(sql: sql, error: message)
                    }
                }
            }
        }

        XCTAssertEqual(queryStarted.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancelled query to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let sanityCheck = try await pool.withConnection(operation: "post_interrupt_sanity_check") { connection in
            guard let db = connection.getConnection() else {
                throw DatabaseConnectionError.notConnected
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1", -1, &statement, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw DatabaseConnectionError.statementPreparationFailed(sql: "SELECT 1", error: message)
            }
            defer {
                sqlite3_finalize(statement)
            }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(db))
                throw DatabaseConnectionError.executionFailed(sql: "SELECT 1", error: message)
            }

            return sqlite3_column_int(statement, 0)
        }

        XCTAssertEqual(sanityCheck, 1)
    }

    func testDBStorageSnapshotsQueryReturnsRecordedRowsForFileDatabase() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceReadSnapshotTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("retrace.db").path
        let fileDatabase = DatabaseManager(databasePath: dbPath)
        defer {
            Task {
                try? await fileDatabase.close()
            }
        }

        try await fileDatabase.initialize()

        let firstDay = makeDate(year: 2026, month: 3, day: 25, hour: 9, minute: 0)
        let secondDay = makeDate(year: 2026, month: 3, day: 26, hour: 9, minute: 0)

        try await fileDatabase.recordDBStorageSnapshot(timestamp: firstDay)
        try await fileDatabase.recordDBStorageSnapshot(timestamp: secondDay)

        let snapshots = try await fileDatabase.getDBStorageSnapshots(
            from: firstDay,
            to: secondDay
        )

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(
            snapshots.map { Calendar.current.startOfDay(for: $0.date) },
            [firstDay, secondDay].map { Calendar.current.startOfDay(for: $0) }
        )
    }

    func testDBStorageSnapshotsQueryUsesNamedInMemoryDatabase() async throws {
        let day = makeDate(year: 2026, month: 3, day: 27, hour: 10, minute: 0)
        let sampledAt = Int64(day.timeIntervalSince1970 * 1000)
        try await executeRawSQL(
            """
            INSERT INTO db_storage_snapshot (local_day, db_bytes, wal_bytes, sampled_at)
            VALUES ('\(localDayString(for: day))', 111, 22, \(sampledAt));
            """
        )

        let snapshots = try await database.getDBStorageSnapshots(from: day, to: day)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots.first.map { Calendar.current.startOfDay(for: $0.date) },
            Calendar.current.startOfDay(for: day)
        )
    }

    func testDatabaseSupportsFTS5VirtualTablesAtRuntime() async throws {
        guard let db = await database.getConnection() else {
            XCTFail("Database connection should be available after initialization")
            return
        }

        try executeRawSQL(
            """
            CREATE VIRTUAL TABLE temp.retrace_fts5_runtime_probe USING fts5(content);
            """,
            db: db
        )

        XCTAssertEqual(
            try fetchInt64(
                """
                SELECT COUNT(*)
                FROM sqlite_temp_master
                WHERE type = 'table' AND name = 'retrace_fts5_runtime_probe';
                """,
                db: db
            ),
            1
        )

        try executeRawSQL("DROP TABLE temp.retrace_fts5_runtime_probe;", db: db)
    }

    func testMigrationFromV14LeavesLegacyDocSegmentAndFTSStateUntouched() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDatabaseLegacyMigrationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        let dbPath = testRoot.appendingPathComponent("legacy-retrace.db").path

        let segmentID: Int64 = 10_000_111
        let videoID: Int64 = 1_000_111
        let frameID: Int64 = 50_000_111
        let missingFrameID: Int64 = 50_999_999
        let timestampMs: Int64 = 1_700_000_000_000

        do {
            let legacyDB = try openRawDatabase(at: dbPath)
            defer {
                sqlite3_close(legacyDB)
            }

            try await runLegacyMigrations(throughVersion: 14, db: legacyDB)

            try executeRawSQL(
                """
                INSERT INTO segment (id, bundleID, startDate, endDate, windowName, browserUrl, type)
                VALUES (\(segmentID), 'com.test.legacy', \(timestampMs), \(timestampMs + 1_000), 'Legacy Window', NULL, 0);
                """,
                db: legacyDB
            )
            try executeRawSQL(
                """
                INSERT INTO video (id, height, width, path, fileSize, frameRate, uploadedAt, xid, processingState, frameCount)
                VALUES (\(videoID), 720, 1280, 'chunks/202603/17/\(videoID)', 4096, 30.0, \(timestampMs), NULL, 0, 1);
                """,
                db: legacyDB
            )
            try executeRawSQL(
                """
                INSERT INTO frame (
                    id, createdAt, imageFileName, segmentId, videoId, videoFrameIndex,
                    isStarred, processingStatus
                )
                VALUES (
                    \(frameID), \(timestampMs), 'legacy-frame.jpg', \(segmentID), \(videoID), 0,
                    0, 2
                );
                """,
                db: legacyDB
            )

            try executeRawSQL(
                "INSERT INTO searchRanking(rowid, text, otherText, title) VALUES (101, 'legacy old text', NULL, 'Legacy');",
                db: legacyDB
            )
            try executeRawSQL(
                "INSERT INTO searchRanking(rowid, text, otherText, title) VALUES (102, 'legacy current text', NULL, 'Legacy');",
                db: legacyDB
            )
            try executeRawSQL(
                "INSERT INTO searchRanking(rowid, text, otherText, title) VALUES (103, 'orphan stale text', NULL, 'Orphan');",
                db: legacyDB
            )

            try executeRawSQL(
                "INSERT INTO doc_segment (docid, segmentId, frameId) VALUES (101, \(segmentID), \(frameID));",
                db: legacyDB
            )
            try executeRawSQL(
                "INSERT INTO doc_segment (docid, segmentId, frameId) VALUES (102, \(segmentID), \(frameID));",
                db: legacyDB
            )
            try executeRawSQL(
                "INSERT INTO doc_segment (docid, segmentId, frameId) VALUES (103, \(segmentID), \(missingFrameID));",
                db: legacyDB
            )
        }

        let migratedDatabase = DatabaseManager(databasePath: dbPath)
        try await migratedDatabase.initialize()

        let migratedConnectionOptional = await migratedDatabase.getConnection()
        let migratedConnection = try XCTUnwrap(migratedConnectionOptional)

        XCTAssertEqual(
            try fetchInt64(
                "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
                db: migratedConnection,
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, frameID)
                }
            ),
            2
        )
        XCTAssertEqual(
            try fetchInt64(
                "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
                db: migratedConnection,
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, missingFrameID)
                }
            ),
            1
        )
        XCTAssertEqual(try fetchInt64("SELECT COUNT(*) FROM searchRanking WHERE rowid = 101;", db: migratedConnection), 1)
        XCTAssertEqual(try fetchInt64("SELECT COUNT(*) FROM searchRanking WHERE rowid = 102;", db: migratedConnection), 1)
        XCTAssertEqual(try fetchInt64("SELECT COUNT(*) FROM searchRanking WHERE rowid = 103;", db: migratedConnection), 1)
        XCTAssertEqual(
            try fetchInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'index_doc_segment_on_frameid_unique';",
                db: migratedConnection
            ),
            0
        )
        XCTAssertEqual(
            try fetchInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'trigger_frame_delete_doc_segment_cleanup';",
                db: migratedConnection
            ),
            0
        )
        XCTAssertEqual(
            try fetchInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'trigger_doc_segment_delete_search_cleanup';",
                db: migratedConnection
            ),
            0
        )
        try await migratedDatabase.close()
    }

    func testNodeTableIncludesEncryptedTextColumnAndOmitsLegacyRedactedColumn() async throws {
        let columnNames = try await tableColumnNames("node")
        XCTAssertTrue(columnNames.contains("encryptedText"))
        XCTAssertFalse(columnNames.contains("redacted"))
    }

    func testGetOCRNodesWithTextReturnsMaskedVisibleTextAndProtectedPayloadForRedactedNode() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let segmentID = try await fetchInt64(
            "SELECT segmentId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        let ciphertext = try XCTUnwrap(
            ReversibleOCRScrambler.encryptOCRText(
                "secret",
                frameID: frameID.value,
                nodeOrder: 0,
                secret: "unit-test-secret"
            )
        )
        let docid = try await database.indexFrameText(
            mainText: String(repeating: " ", count: 6),
            chromeText: nil,
            windowTitle: nil,
            segmentId: segmentID,
            frameId: frameID.value
        )

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: ciphertext],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        let uiNodes = try await database.getOCRNodesWithText(frameID: frameID)
        let dbNodes = try await database.getNodesWithText(
            frameID: frameID,
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        let storedContent = try await database.getFTSContent(docid: docid)

        XCTAssertEqual(uiNodes.count, 1)
        XCTAssertEqual(uiNodes[0].text, String(repeating: " ", count: 6))
        XCTAssertEqual(uiNodes[0].encryptedText, ciphertext)
        XCTAssertTrue(uiNodes[0].isRedacted)

        XCTAssertEqual(dbNodes.count, 1)
        XCTAssertEqual(dbNodes[0].text, String(repeating: " ", count: 6))
        XCTAssertTrue(dbNodes[0].node.isRedacted)

        XCTAssertEqual(storedContent?.mainText, String(repeating: " ", count: 6))
    }

    func testGetOCRNodesWithTextReturnsProtectedPayloadWithoutFTSDocument() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let ciphertext = try XCTUnwrap(
            ReversibleOCRScrambler.encryptOCRText(
                "secret",
                frameID: frameID.value,
                nodeOrder: 0,
                secret: "unit-test-secret"
            )
        )

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: ciphertext],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        let uiNodes = try await database.getOCRNodesWithText(frameID: frameID)
        let dbNodes = try await database.getNodesWithText(
            frameID: frameID,
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        XCTAssertEqual(uiNodes.count, 1)
        XCTAssertEqual(uiNodes[0].text, String(repeating: " ", count: 6))
        XCTAssertEqual(uiNodes[0].encryptedText, ciphertext)
        XCTAssertTrue(uiNodes[0].isRedacted)

        XCTAssertEqual(dbNodes.count, 1)
        XCTAssertEqual(dbNodes[0].text, String(repeating: " ", count: 6))
        XCTAssertTrue(dbNodes[0].node.isRedacted)
    }

    func testIndexFrameTextReplacesExistingDocSegmentForFrame() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let segmentID = try await fetchInt64(
            "SELECT segmentId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )

        _ = try await database.indexFrameText(
            mainText: "alpha",
            chromeText: nil,
            windowTitle: "First",
            segmentId: segmentID,
            frameId: frameID.value
        )
        let secondDocid = try await database.indexFrameText(
            mainText: "beta",
            chromeText: "chrome",
            windowTitle: "Second",
            segmentId: segmentID,
            frameId: frameID.value
        )

        let docSegmentCount = try await fetchInt64(
            "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        let currentDocid = try await database.getDocidForFrame(frameId: frameID.value)
        let content = try await database.getFTSContent(docid: try XCTUnwrap(currentDocid))

        XCTAssertEqual(docSegmentCount, 1)
        XCTAssertEqual(currentDocid, secondDocid)
        XCTAssertEqual(content?.mainText, "beta")
        XCTAssertEqual(content?.chromeText, "chrome")
        XCTAssertEqual(content?.windowTitle, "Second")
    }

    func testDeleteFrameRemovesAssociatedFTSRowsFromCoreDatabasePath() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let segmentID = try await fetchInt64(
            "SELECT segmentId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )

        let docid = try await database.indexFrameText(
            mainText: "delete me",
            chromeText: nil,
            windowTitle: nil,
            segmentId: segmentID,
            frameId: frameID.value
        )

        try await database.deleteFrame(id: frameID)

        let remainingDocSegments = try await fetchInt64(
            "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        let remainingFTSRows = try await fetchInt64(
            "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, docid)
            }
        )

        XCTAssertEqual(remainingDocSegments, 0)
        XCTAssertEqual(remainingFTSRows, 0)
    }

    func testDeleteFramesOlderThanRemovesAssociatedFTSRows() async throws {
        let now = Date()
        let oldTimestamp = now.addingTimeInterval(-3_600)
        let newTimestamp = now.addingTimeInterval(3_600)

        let oldFrameID = try await insertTestFrame(browserURL: nil, timestamp: oldTimestamp)
        let newFrameID = try await insertTestFrame(browserURL: nil, timestamp: newTimestamp)

        let oldSegmentID = try await fetchInt64(
            "SELECT segmentId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, oldFrameID.value)
            }
        )
        let newSegmentID = try await fetchInt64(
            "SELECT segmentId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, newFrameID.value)
            }
        )

        let oldDocid = try await database.indexFrameText(
            mainText: "old frame",
            chromeText: nil,
            windowTitle: nil,
            segmentId: oldSegmentID,
            frameId: oldFrameID.value
        )
        let newDocid = try await database.indexFrameText(
            mainText: "new frame",
            chromeText: nil,
            windowTitle: nil,
            segmentId: newSegmentID,
            frameId: newFrameID.value
        )

        let deletedCount = try await database.deleteFrames(olderThan: now)
        let deletedOldFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, oldFrameID.value)
            }
        )
        let deletedOldFTSCount = try await fetchInt64(
            "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, oldDocid)
            }
        )
        let survivingNewFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, newFrameID.value)
            }
        )
        let survivingNewFTSCount = try await fetchInt64(
            "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, newDocid)
            }
        )

        XCTAssertEqual(deletedCount, 1)
        XCTAssertEqual(deletedOldFrameCount, 0)
        XCTAssertEqual(deletedOldFTSCount, 0)
        XCTAssertEqual(survivingNewFrameCount, 1)
        XCTAssertEqual(survivingNewFTSCount, 1)
    }

    func testUpdateFrameProcessingStatusStoresRewrittenAtWithoutOverwritingProcessedAt() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)

        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 2)
        let processedAtAfterOCR = try await fetchInt64(
            """
            SELECT processedAt
            FROM frame
            WHERE id = ?
              AND processingStatus = 2
              AND processedAt IS NOT NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )

        try await database.updateFrameProcessingStatus(
            frameID: frameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        let pendingRewriteCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 5
              AND rewritePurpose = 'redaction';
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        XCTAssertEqual(pendingRewriteCount, 1)
        let unsetRewrittenAtCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND rewrittenAt IS NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        XCTAssertEqual(unsetRewrittenAtCount, 1)

        try await database.updateFrameProcessingStatus(
            frameID: frameID.value,
            status: 7,
            rewritePurpose: "redaction"
        )

        let completedRewriteCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 7
              AND rewritePurpose = 'redaction'
              AND processedAt = ?
              AND rewrittenAt IS NOT NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
                sqlite3_bind_int64(statement, 2, processedAtAfterOCR)
            }
        )
        XCTAssertEqual(completedRewriteCount, 1)

        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 0)

        let resetToPendingCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 0
              AND rewritePurpose IS NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        XCTAssertEqual(resetToPendingCount, 1)
    }

    func testGetFrameStatusCountsSeparatesOCRAndRewriteLanes() async throws {
        let ocrPendingFrameID = try await insertTestFrame(browserURL: nil)
        let ocrProcessingFrameID = try await insertTestFrame(browserURL: nil)
        let rewritePendingFrameID = try await insertTestFrame(browserURL: nil)
        let rewriteProcessingFrameID = try await insertTestFrame(browserURL: nil)

        try await database.updateFrameProcessingStatus(frameID: ocrPendingFrameID.value, status: 0)
        try await database.updateFrameProcessingStatus(frameID: ocrProcessingFrameID.value, status: 1)
        try await database.updateFrameProcessingStatus(
            frameID: rewritePendingFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: rewriteProcessingFrameID.value,
            status: 6,
            rewritePurpose: "redaction"
        )

        let counts = try await database.getFrameStatusCounts()

        XCTAssertEqual(counts.ocrPending, 1)
        XCTAssertEqual(counts.ocrProcessing, 1)
        XCTAssertEqual(counts.rewritePending, 1)
        XCTAssertEqual(counts.rewriteProcessing, 1)
    }

    func testMarkFrameReadableStoresEncodedAt() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)

        let beforeEncodedAtCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND encodedAt IS NOT NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        XCTAssertEqual(beforeEncodedAtCount, 0)

        try await database.markFrameReadable(frameID: frameID.value)

        let readableCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 0
              AND encodedAt IS NOT NULL;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )
        XCTAssertEqual(readableCount, 1)
    }

    func testGetUnreadableFrameCountWithinLastMinutesIgnoresOlderFrames() async throws {
        _ = try await insertTestFrame(
            browserURL: nil,
            timestamp: Date()
        )
        _ = try await insertTestFrame(
            browserURL: nil,
            timestamp: Date().addingTimeInterval(-10 * 60)
        )
        let readableFrameID = try await insertTestFrame(
            browserURL: nil,
            timestamp: Date().addingTimeInterval(-60)
        )

        try await database.markFrameReadable(frameID: readableFrameID.value)

        let recentUnreadableCount = try await database.getUnreadableFrameCount(withinLastMinutes: 5)
        let totalUnreadableCount = try await database.getUnreadableFrameCount()

        XCTAssertEqual(recentUnreadableCount, 1)
        XCTAssertEqual(totalUnreadableCount, 2)
    }

    func testGetFramesEncodedPerMinuteBucketsByEncodedAt() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let currentMinuteMs = (nowMs / 60_000) * 60_000

        let currentMinuteFrameID = try await insertTestFrame(browserURL: nil)
        let previousMinuteFrameID = try await insertTestFrame(browserURL: nil)
        let oldFrameID = try await insertTestFrame(browserURL: nil)

        try await database.markFrameReadable(frameID: currentMinuteFrameID.value)
        try await database.markFrameReadable(frameID: previousMinuteFrameID.value)
        try await database.markFrameReadable(frameID: oldFrameID.value)

        try await executeRawSQL(
            """
            UPDATE frame
            SET encodedAt = CASE id
                WHEN \(currentMinuteFrameID.value) THEN \(currentMinuteMs + 5_000)
                WHEN \(previousMinuteFrameID.value) THEN \(currentMinuteMs - 60_000 + 5_000)
                WHEN \(oldFrameID.value) THEN \(currentMinuteMs - 31 * 60_000)
            END
            WHERE id IN (\(currentMinuteFrameID.value), \(previousMinuteFrameID.value), \(oldFrameID.value));
            """
        )

        let buckets = try await database.getFramesEncodedPerMinute(lastMinutes: 30)

        XCTAssertEqual(buckets[0], 1)
        XCTAssertEqual(buckets[1], 1)
        XCTAssertNil(buckets[29])
    }

    func testGetFramesRewrittenPerMinuteBucketsByRewrittenAt() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let currentMinuteMs = (nowMs / 60_000) * 60_000

        let currentMinuteFrameID = try await insertTestFrame(browserURL: nil)
        let previousMinuteFrameID = try await insertTestFrame(browserURL: nil)
        let oldFrameID = try await insertTestFrame(browserURL: nil)

        try await database.updateFrameProcessingStatus(
            frameID: currentMinuteFrameID.value,
            status: 7,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: previousMinuteFrameID.value,
            status: 7,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: oldFrameID.value,
            status: 7,
            rewritePurpose: "redaction"
        )

        try await executeRawSQL(
            """
            UPDATE frame
            SET rewrittenAt = CASE id
                WHEN \(currentMinuteFrameID.value) THEN \(currentMinuteMs + 5_000)
                WHEN \(previousMinuteFrameID.value) THEN \(currentMinuteMs - 60_000 + 5_000)
                WHEN \(oldFrameID.value) THEN \(currentMinuteMs - 31 * 60_000)
            END
            WHERE id IN (\(currentMinuteFrameID.value), \(previousMinuteFrameID.value), \(oldFrameID.value));
            """
        )

        let buckets = try await database.getFramesRewrittenPerMinute(lastMinutes: 30)

        XCTAssertEqual(buckets[0], 1)
        XCTAssertEqual(buckets[1], 1)
        XCTAssertNil(buckets[29])
    }

    func testPendingNodeRedactionQueriesCanIncludeRetryableFailures() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let videoID = try await fetchInt64(
            "SELECT videoId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await database.updateFrameProcessingStatus(
            frameID: frameID.value,
            status: 8,
            rewritePurpose: "redaction"
        )

        let defaultPendingVideoIDs = try await database.getVideoIDsWithPendingNodeRedactions()
        let retryablePendingVideoIDs = try await database.getVideoIDsWithPendingNodeRedactions(
            includeRetryableFailures: true
        )
        let defaultJobs = try await database.getPendingNodeRedactionJobs(videoID: videoID)
        let retryableJobs = try await database.getPendingNodeRedactionJobs(
            videoID: videoID,
            includeRetryableFailures: true
        )

        XCTAssertTrue(defaultPendingVideoIDs.isEmpty)
        XCTAssertEqual(retryablePendingVideoIDs, [videoID])
        XCTAssertTrue(defaultJobs.isEmpty)
        XCTAssertEqual(retryableJobs.map(\.frameID), [frameID.value])
    }

    func testDeleteOrScheduleNativeFramesForDeletionDeletesLiveFramesImmediatelyAndSchedulesVideoFrames() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_000_000)
        let appSegmentID = try await insertTestAppSegment(bundleID: "com.apple.Safari")

        let liveFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID.value),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )
        let liveFrameID = FrameID(value: try await database.insertFrame(liveFrame))

        let videoBackedFrameID = try await insertTestFrame(
            browserURL: nil,
            timestamp: timestamp.addingTimeInterval(2)
        )

        try await database.updateFrameProcessingStatus(frameID: liveFrameID.value, status: 0)
        try await database.updateFrameProcessingStatus(frameID: videoBackedFrameID.value, status: 0)
        try await database.enqueueFrameForProcessing(frameID: liveFrameID.value)
        try await database.enqueueFrameForProcessing(frameID: videoBackedFrameID.value)

        let result = try await database.deleteOrScheduleNativeFramesForDeletion(
            frameIDs: [liveFrameID.value, videoBackedFrameID.value]
        )

        XCTAssertEqual(result.immediatelyDeletedFrameIDs, [liveFrameID.value])
        XCTAssertEqual(result.scheduledJobs.map(\.frameID), [videoBackedFrameID.value])

        let liveFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { sqlite3_bind_int64($0, 1, liveFrameID.value) }
        )
        let liveQueueCount = try await fetchInt64(
            "SELECT COUNT(*) FROM processing_queue WHERE frameId = ?;",
            bind: { sqlite3_bind_int64($0, 1, liveFrameID.value) }
        )
        let scheduledQueueCount = try await fetchInt64(
            "SELECT COUNT(*) FROM processing_queue WHERE frameId = ?;",
            bind: { sqlite3_bind_int64($0, 1, videoBackedFrameID.value) }
        )
        let scheduledDeletionCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 5
              AND rewritePurpose = 'deletion';
            """,
            bind: { sqlite3_bind_int64($0, 1, videoBackedFrameID.value) }
        )

        XCTAssertEqual(liveFrameCount, 0)
        XCTAssertEqual(liveQueueCount, 0)
        XCTAssertEqual(scheduledQueueCount, 0)
        XCTAssertEqual(scheduledDeletionCount, 1)
    }

    func testDeleteOrScheduleNativeFramesForDeletionByDateUsesSetBasedSelection() async throws {
        let cutoff = Date(timeIntervalSince1970: 1_775_000_000)
        let appSegmentID = try await insertTestAppSegment(bundleID: "com.apple.Safari")

        let olderLiveFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: cutoff.addingTimeInterval(-10),
            segmentID: AppSegmentID(value: appSegmentID.value),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )
        let olderLiveFrameID = FrameID(value: try await database.insertFrame(olderLiveFrame))

        let recentLiveFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: cutoff.addingTimeInterval(10),
            segmentID: AppSegmentID(value: appSegmentID.value),
            frameIndexInSegment: 1,
            metadata: .empty,
            source: .native
        )
        let recentLiveFrameID = FrameID(value: try await database.insertFrame(recentLiveFrame))

        let recentVideoFrameID = try await insertTestFrame(
            browserURL: nil,
            timestamp: cutoff.addingTimeInterval(20)
        )

        let result = try await database.deleteOrScheduleNativeFramesForDeletion(newerThan: cutoff)

        XCTAssertEqual(result.immediatelyDeletedFrameIDs, [recentLiveFrameID.value])
        XCTAssertEqual(result.scheduledJobs.map(\.frameID), [recentVideoFrameID.value])

        let olderLiveFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { sqlite3_bind_int64($0, 1, olderLiveFrameID.value) }
        )
        let recentLiveFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { sqlite3_bind_int64($0, 1, recentLiveFrameID.value) }
        )
        let scheduledDeletionCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 5
              AND rewritePurpose = 'deletion';
            """,
            bind: { sqlite3_bind_int64($0, 1, recentVideoFrameID.value) }
        )

        XCTAssertEqual(olderLiveFrameCount, 1)
        XCTAssertEqual(recentLiveFrameCount, 0)
        XCTAssertEqual(scheduledDeletionCount, 1)
    }

    func testBuildVideoRewritePlanDetectsWholeVideoDeleteFromRemainingVisibleFrames() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_000_000)
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(30),
                frameCount: 3,
                fileSizeBytes: 1_024,
                relativePath: "segments/rewrite-whole-delete-\(UUID().uuidString).mp4",
                width: 1_920,
                height: 1_080,
                source: .native
            )
        )
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Rewrite Whole Delete",
            browserUrl: nil,
            type: 0
        )

        let alreadyHiddenFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp
        )
        let remainingVisibleFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 2,
            timestamp: timestamp.addingTimeInterval(2)
        )

        try await database.updateFrameProcessingStatus(
            frameID: alreadyHiddenFrameID.value,
            status: 5,
            rewritePurpose: "deletion"
        )
        _ = try await database.deleteOrScheduleNativeFramesForDeletion(frameIDs: [remainingVisibleFrameID.value])

        let maybePlan = try await database.buildVideoRewritePlan(videoID: videoID)
        let plan = try XCTUnwrap(maybePlan)

        XCTAssertEqual(Set(plan.deletionFrameIDs), Set([alreadyHiddenFrameID.value, remainingVisibleFrameID.value]))
        XCTAssertEqual(plan.blackFrameIndexes, Set([0, 2]))
        XCTAssertTrue(plan.deletesWholeVideo)
    }

    func testBuildVideoRewritePlanDropsRedactionTargetsOnlyForDeletedFrameIDs() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_100_000)
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(30),
                frameCount: 2,
                fileSizeBytes: 1_024,
                relativePath: "segments/rewrite-mixed-\(UUID().uuidString).mp4",
                width: 1_920,
                height: 1_080,
                source: .native
            )
        )
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Rewrite Mixed",
            browserUrl: nil,
            type: 0
        )

        let deletedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp
        )
        let redactedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 1,
            timestamp: timestamp.addingTimeInterval(2)
        )

        try await database.insertNodes(
            frameID: deletedFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-delete"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await database.insertNodes(
            frameID: redactedFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 40, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-redact"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        try await database.updateFrameProcessingStatus(
            frameID: deletedFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: redactedFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        _ = try await database.deleteOrScheduleNativeFramesForDeletion(frameIDs: [deletedFrameID.value])

        let maybePlan = try await database.buildVideoRewritePlan(videoID: videoID)
        let plan = try XCTUnwrap(maybePlan)

        XCTAssertEqual(plan.deletionFrameIDs, [deletedFrameID.value])
        XCTAssertEqual(plan.blackFrameIndexes, Set([0]))
        XCTAssertEqual(plan.redactionFrameIDs, [redactedFrameID.value])
        XCTAssertEqual(plan.redactions.map(\.frameID), [redactedFrameID.value])
        XCTAssertEqual(plan.redactions.map(\.frameIndex), [1])
        XCTAssertEqual(plan.segmentRewritePlan.redactionFrameIDs, [redactedFrameID.value])
        XCTAssertFalse(plan.deletesWholeVideo)
    }

    func testBuildVideoRewritePlanPreservesDuplicateFrameIndexRedactionsByFrameID() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_150_000)
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(30),
                frameCount: 2,
                fileSizeBytes: 1_024,
                relativePath: "segments/rewrite-duplicate-redactions-\(UUID().uuidString).mp4",
                width: 1_920,
                height: 1_080,
                source: .native
            )
        )
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Rewrite Duplicate Redactions",
            browserUrl: nil,
            type: 0
        )

        let firstFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp
        )
        let secondFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp.addingTimeInterval(2)
        )

        try await database.insertNodes(
            frameID: firstFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 5,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-first"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await database.insertNodes(
            frameID: secondFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 50, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-second"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        try await database.updateFrameProcessingStatus(
            frameID: firstFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: secondFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        let maybePlan = try await database.buildVideoRewritePlan(videoID: videoID)
        let plan = try XCTUnwrap(maybePlan)

        XCTAssertEqual(Set(plan.redactionFrameIDs), Set([firstFrameID.value, secondFrameID.value]))
        XCTAssertEqual(plan.redactions.count, 2)
        XCTAssertEqual(Set(plan.redactions.map(\.frameIndex)), Set([0]))
        XCTAssertEqual(Set(plan.segmentRewritePlan.redactionFrameIDs), Set([firstFrameID.value, secondFrameID.value]))
    }

    func testBuildVideoRewritePlanKeepsDuplicateFrameIndexRedactionWhenSiblingFrameIsDeleted() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_160_000)
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(30),
                frameCount: 2,
                fileSizeBytes: 1_024,
                relativePath: "segments/rewrite-duplicate-delete-redact-\(UUID().uuidString).mp4",
                width: 1_920,
                height: 1_080,
                source: .native
            )
        )
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Rewrite Duplicate Delete Redact",
            browserUrl: nil,
            type: 0
        )

        let deletedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp
        )
        let redactedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp.addingTimeInterval(2)
        )

        try await database.insertNodes(
            frameID: redactedFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 50, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-duplicate-redact"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )

        try await database.updateFrameProcessingStatus(
            frameID: deletedFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )
        try await database.updateFrameProcessingStatus(
            frameID: redactedFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        _ = try await database.deleteOrScheduleNativeFramesForDeletion(frameIDs: [deletedFrameID.value])

        let maybePlan = try await database.buildVideoRewritePlan(videoID: videoID)
        let plan = try XCTUnwrap(maybePlan)

        XCTAssertEqual(plan.deletionFrameIDs, [deletedFrameID.value])
        XCTAssertEqual(plan.blackFrameIndexes, Set([0]))
        XCTAssertEqual(plan.redactionFrameIDs, [redactedFrameID.value])
        XCTAssertEqual(plan.redactions.map(\.frameIndex), [0])
        XCTAssertEqual(plan.segmentRewritePlan.redactionFrameIDs, [redactedFrameID.value])
    }

    func testFinalizeVideoRewriteDeletesDeletionFramesAndMarksRedactionsCompleted() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_775_200_000)
        let videoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(30),
                frameCount: 2,
                fileSizeBytes: 1_024,
                relativePath: "segments/rewrite-finalize-\(UUID().uuidString).mp4",
                width: 1_920,
                height: 1_080,
                source: .native
            )
        )
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Rewrite Finalize",
            browserUrl: nil,
            type: 0
        )

        let deletedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 0,
            timestamp: timestamp
        )
        let redactedFrameID = try await insertTestFrame(
            videoID: videoID,
            segmentID: appSegmentID,
            frameIndex: 1,
            timestamp: timestamp.addingTimeInterval(2)
        )

        let deletedDocID = try await database.indexFrameText(
            mainText: "delete me",
            chromeText: nil,
            windowTitle: nil,
            segmentId: appSegmentID,
            frameId: deletedFrameID.value
        )
        _ = try await database.indexFrameText(
            mainText: "redact me",
            chromeText: nil,
            windowTitle: nil,
            segmentId: appSegmentID,
            frameId: redactedFrameID.value
        )

        try await database.insertNodes(
            frameID: redactedFrameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 40, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher-redact"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await database.updateFrameProcessingStatus(
            frameID: redactedFrameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )
        _ = try await database.deleteOrScheduleNativeFramesForDeletion(frameIDs: [deletedFrameID.value])

        let maybePlan = try await database.buildVideoRewritePlan(videoID: videoID)
        let plan = try XCTUnwrap(maybePlan)
        try await database.finalizeVideoRewrite(plan)

        let deletedFrameCount = try await fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = ?;",
            bind: { sqlite3_bind_int64($0, 1, deletedFrameID.value) }
        )
        let deletedDocSegmentCount = try await fetchInt64(
            "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?;",
            bind: { sqlite3_bind_int64($0, 1, deletedFrameID.value) }
        )
        let deletedSearchRowCount = try await fetchInt64(
            "SELECT COUNT(*) FROM searchRanking WHERE rowid = ?;",
            bind: { sqlite3_bind_int64($0, 1, deletedDocID) }
        )
        let redactedFrameCompletedCount = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND processingStatus = 7
              AND rewritePurpose = 'redaction'
              AND rewrittenAt IS NOT NULL;
            """,
            bind: { sqlite3_bind_int64($0, 1, redactedFrameID.value) }
        )
        let videoCount = try await fetchInt64(
            "SELECT COUNT(*) FROM video WHERE id = ?;",
            bind: { sqlite3_bind_int64($0, 1, videoID) }
        )

        XCTAssertEqual(deletedFrameCount, 0)
        XCTAssertEqual(deletedDocSegmentCount, 0)
        XCTAssertEqual(deletedSearchRowCount, 0)
        XCTAssertEqual(redactedFrameCompletedCount, 1)
        XCTAssertEqual(videoCount, 1)
    }

    func testFinalizeVideoRewriteRefreshesVideoFileSizeFromDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceRewriteFileSizeRefresh_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let isolatedDatabase = DatabaseManager(
            databasePath: "file:rewrite_filesize_refresh_\(UUID().uuidString)?mode=memory&cache=private",
            storageRootPath: tempDir.path
        )

        do {
            try await isolatedDatabase.initialize()

            let relativePath = "chunks/202604/08/rewrite-filesize-\(UUID().uuidString).mp4"
            let segmentURL = tempDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: segmentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let onDiskFileSize = 6_355_843
            try Data(repeating: 0x7A, count: onDiskFileSize).write(to: segmentURL)

            let timestamp = Date(timeIntervalSince1970: 1_775_200_000)
            let videoID = try await isolatedDatabase.insertVideoSegment(
                VideoSegment(
                    id: VideoSegmentID(value: 0),
                    startTime: timestamp,
                    endTime: timestamp.addingTimeInterval(5),
                    frameCount: 150,
                    fileSizeBytes: 5_794_598,
                    relativePath: relativePath,
                    width: 3024,
                    height: 1964,
                    source: .native
                )
            )

            let plan = VideoRewritePlan(
                videoID: videoID,
                redactions: [
                    VideoFrameRedaction(
                        frameID: 999_999_999,
                        frameIndex: 0,
                        targets: []
                    )
                ]
            )
            try await isolatedDatabase.finalizeVideoRewrite(plan)

            guard let db = await isolatedDatabase.getConnection() else {
                XCTFail("Expected active database connection")
                return
            }

            let refreshedSize = try fetchInt64(
                "SELECT fileSize FROM video WHERE id = ?;",
                db: db,
                bind: { sqlite3_bind_int64($0, 1, videoID) }
            )
            XCTAssertEqual(refreshedSize, Int64(onDiskFileSize))

            try await isolatedDatabase.close()
        } catch {
            try? await isolatedDatabase.close()
            throw error
        }
    }

    func testHasProtectedPhraseRedactionDataReturnsTrueWhenEncryptedNodesExist() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let hasProtectedDataBeforeInsert = try await database.hasProtectedPhraseRedactionData()

        XCTAssertFalse(hasProtectedDataBeforeInsert)

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        let hasProtectedDataAfterInsert = try await database.hasProtectedPhraseRedactionData()

        XCTAssertTrue(hasProtectedDataAfterInsert)
    }

    func testAbandonPendingNodeRedactionsMarksJobsFailedAndRemovesThemFromRetryScan() async throws {
        let frameID = try await insertTestFrame(browserURL: nil)
        let videoID = try await fetchInt64(
            "SELECT videoId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
            }
        )

        try await database.insertNodes(
            frameID: frameID,
            nodes: [(
                textOffset: 0,
                textLength: 6,
                bounds: CGRect(x: 10, y: 10, width: 120, height: 24),
                windowIndex: nil
            )],
            encryptedTexts: [0: "cipher"],
            frameWidth: 1_000,
            frameHeight: 1_000
        )
        try await database.updateFrameProcessingStatus(
            frameID: frameID.value,
            status: 5,
            rewritePurpose: "redaction"
        )

        let abandonedCount = try await database.abandonPendingNodeRedactions(
            missingKeyRewritePurpose: "redaction_missing_master_key_abandoned"
        )
        let pendingVideoIDs = try await database.getVideoIDsWithPendingNodeRedactions(
            includeRetryableFailures: true
        )
        let abandonedFrames = try await fetchInt64(
            """
            SELECT COUNT(*)
            FROM frame
            WHERE id = ?
              AND videoId = ?
              AND processingStatus = 8
              AND rewritePurpose = 'redaction_missing_master_key_abandoned';
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, frameID.value)
                sqlite3_bind_int64(statement, 2, videoID)
            }
        )

        XCTAssertEqual(abandonedCount, 1)
        XCTAssertTrue(pendingVideoIDs.isEmpty)
        XCTAssertEqual(abandonedFrames, 1)
    }

    func testVideoHasFramesAwaitingOCRReturnsTrueForPendingStatuses() async throws {
        let firstFrameID = try await insertTestFrame(browserURL: nil)
        let secondFrameID = try await insertTestFrame(browserURL: nil)

        try await executeRawSQL(
            """
            UPDATE frame
            SET videoId = (SELECT videoId FROM frame WHERE id = \(firstFrameID.value))
            WHERE id = \(secondFrameID.value);
            """
        )

        try await database.updateFrameProcessingStatus(frameID: firstFrameID.value, status: 5)
        try await database.updateFrameProcessingStatus(frameID: secondFrameID.value, status: 1)

        let hasAwaitingOCR = try await database.videoHasFramesAwaitingOCR(
            videoID: try await fetchInt64(
                "SELECT videoId FROM frame WHERE id = ?;",
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, firstFrameID.value)
                }
            )
        )

        XCTAssertTrue(hasAwaitingOCR)
    }

    func testRecordDBStorageSnapshotUpsertsSingleRowWithinSameDay() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDBStorageSnapshotSameDay_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dbPath = tempDir.appendingPathComponent("retrace.db").path
        let fileDatabase = DatabaseManager(
            databasePath: dbPath,
            storageRootPath: tempDir.path
        )

        do {
            try await fileDatabase.initialize()

            let morning = Date(timeIntervalSince1970: 1_773_420_000)
            let laterSameDay = morning.addingTimeInterval(600)

            try await fileDatabase.recordDBStorageSnapshot(timestamp: morning)
            try await fileDatabase.recordDBStorageSnapshot(timestamp: laterSameDay)

            guard let db = await fileDatabase.getConnection() else {
                XCTFail("Expected active database connection")
                return
            }

            let rowCount = try fetchInt64(
                "SELECT COUNT(*) FROM db_storage_snapshot;",
                db: db
            )
            XCTAssertEqual(rowCount, 1)

            let sampledAt = try fetchInt64(
                "SELECT sampled_at FROM db_storage_snapshot LIMIT 1;",
                db: db
            )
            XCTAssertEqual(sampledAt, Int64(laterSameDay.timeIntervalSince1970 * 1000))

            let dbBytes = try fetchInt64(
                "SELECT db_bytes FROM db_storage_snapshot LIMIT 1;",
                db: db
            )
            XCTAssertGreaterThan(dbBytes, 0)

            try await fileDatabase.close()
        } catch {
            try? await fileDatabase.close()
            throw error
        }
    }

    func testRecordDBStorageSnapshotCreatesDistinctRowsAcrossDays() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDBStorageSnapshotMultiDay_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dbPath = tempDir.appendingPathComponent("retrace.db").path
        let fileDatabase = DatabaseManager(
            databasePath: dbPath,
            storageRootPath: tempDir.path
        )

        do {
            try await fileDatabase.initialize()

            let firstDay = Date(timeIntervalSince1970: 1_773_420_000)
            let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)

            try await fileDatabase.recordDBStorageSnapshot(timestamp: firstDay)
            try await fileDatabase.recordDBStorageSnapshot(timestamp: secondDay)

            let snapshots = try await fileDatabase.getDBStorageSnapshots(
                from: firstDay,
                to: secondDay
            )

            XCTAssertEqual(snapshots.count, 2)
            XCTAssertLessThan(snapshots[0].date, snapshots[1].date)

            try await fileDatabase.close()
        } catch {
            try? await fileDatabase.close()
            throw error
        }
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ SEGMENT TESTS                                                           │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetSegment() async throws {
        print("[TEST DEBUG] testInsertAndGetSegment() started")
        // Create a test segment
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300), // 5 minutes
            frameCount: 150,
            fileSizeBytes: 1024 * 1024 * 50, // 50MB
            relativePath: "segments/2024/01/segment-001.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        print("[TEST DEBUG] Segment created")

        // Insert segment
        print("[TEST DEBUG] Inserting segment...")
        let insertedSegmentID = try await database.insertVideoSegment(segment)
        print("[TEST DEBUG] Segment inserted")

        // Retrieve segment
        print("[TEST DEBUG] Retrieving segment...")
        let retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        print("[TEST DEBUG] Segment retrieved")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedSegmentID)
        XCTAssertEqual(retrieved?.frameCount, 150)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024 * 1024 * 50)
        XCTAssertEqual(retrieved?.relativePath, "segments/2024/01/segment-001.mp4")
        print("[TEST DEBUG] testInsertAndGetSegment() complete")
    }

    func testGetSegmentContainingTimestamp() async throws {
        let now = Date()
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: now.addingTimeInterval(-600), // 10 minutes ago
            endTime: now.addingTimeInterval(-300),   // 5 minutes ago
            frameCount: 150,
            fileSizeBytes: 1024 * 1024 * 50,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let insertedSegmentID = try await database.insertVideoSegment(segment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(-300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // getVideoSegment(containingTimestamp:) resolves via exact frame.createdAt match.
        let timestampInRange = now.addingTimeInterval(-450)
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestampInRange,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedSegmentID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )
        _ = try await database.insertFrame(frame)

        // Query for timestamp within the segment
        let retrieved = try await database.getVideoSegment(containingTimestamp: timestampInRange)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedSegmentID)

        // Query for timestamp outside the segment
        let timestampOutOfRange = now.addingTimeInterval(-449)
        let shouldBeNil = try await database.getVideoSegment(containingTimestamp: timestampOutOfRange)
        XCTAssertNil(shouldBeNil)
    }

    func testDeleteSegment() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/to-delete.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let insertedSegmentID = try await database.insertVideoSegment(segment)

        // Verify it exists
        var retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        XCTAssertNotNil(retrieved)

        // Delete it
        try await database.deleteVideoSegment(id: VideoSegmentID(value: insertedSegmentID))

        // Verify it's gone
        retrieved = try await database.getVideoSegment(id: VideoSegmentID(value: insertedSegmentID))
        XCTAssertNil(retrieved)
    }

    func testUpdateSegmentBrowserURL_DefaultDoesNotOverwriteExistingValue() async throws {
        let segmentID = try await database.insertSegment(
            bundleID: "com.google.Chrome",
            startDate: Date(),
            endDate: Date(),
            windowName: "Search",
            browserUrl: "https://example.com/old",
            type: 0
        )

        try await database.updateSegmentBrowserURL(
            id: segmentID,
            browserURL: "https://example.com/new"
        )

        let segment = try await database.getSegment(id: segmentID)
        XCTAssertEqual(segment?.browserUrl, "https://example.com/old")
    }

    func testUpdateSegmentBrowserURL_AllowsOverwriteWhenRequested() async throws {
        let segmentID = try await database.insertSegment(
            bundleID: "com.google.Chrome",
            startDate: Date(),
            endDate: Date(),
            windowName: "Search",
            browserUrl: "https://example.com/old",
            type: 0
        )

        try await database.updateSegmentBrowserURL(
            id: segmentID,
            browserURL: "https://example.com/new",
            onlyIfNull: false
        )

        let segment = try await database.getSegment(id: segmentID)
        XCTAssertEqual(segment?.browserUrl, "https://example.com/new")
    }

    func testGetTotalStorageBytes() async throws {
        let segment1 = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024 * 10, // 10MB
            relativePath: "segments/1.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let segment2 = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date().addingTimeInterval(300),
            endTime: Date().addingTimeInterval(600),
            frameCount: 100,
            fileSizeBytes: 1024 * 1024 * 20, // 20MB
            relativePath: "segments/2.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        try await database.insertVideoSegment(segment1)
        try await database.insertVideoSegment(segment2)

        let total = try await database.getTotalStorageBytes()
        XCTAssertEqual(total, 1024 * 1024 * 30) // 30MB
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ FRAME TESTS                                                             │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testInsertAndGetFrame() async throws {
        let timestamp = Date()

        // First, create a video segment (frames need a valid segment_id)
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        // Create app segment
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "Retrace - GitHub",
            browserUrl: "https://github.com/retrace",
            type: 0
        )

        // Create a test frame
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Retrace - GitHub",
                browserURL: "https://github.com/retrace",
                captureTrigger: .mouse
            ),
            source: .native
        )

        // Insert frame
        let insertedFrameID = try await database.insertFrame(frame)

        // Retrieve frame
        let retrieved = try await database.getFrame(id: FrameID(value: insertedFrameID))

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id.value, insertedFrameID)
        XCTAssertEqual(retrieved?.segmentID.value, appSegmentID)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertEqual(retrieved?.metadata.windowName, "Retrace - GitHub")
        XCTAssertEqual(retrieved?.metadata.captureTrigger, .mouse)
    }

    func testInsertFrameLeavesEncodedAtNull() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/null-encoding-status.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "NULL Encoding Status",
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let insertedFrameID = try await database.insertFrame(frame)
        let storedEncodedAt = try await fetchText(
            "SELECT encodedAt FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, insertedFrameID)
            }
        )

        XCTAssertNil(storedEncodedAt)
    }

    func testUpdateFrameVideoLinkLeavesEncodedAtNull() async throws {
        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Video Link Update",
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: 0),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )
        let insertedFrameID = try await database.insertFrame(frame)

        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/video-link-update.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        try await database.updateFrameVideoLink(
            frameID: FrameID(value: insertedFrameID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndex: 7
        )

        let storedEncodedAt = try await fetchText(
            "SELECT encodedAt FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, insertedFrameID)
            }
        )
        let storedVideoID = try await fetchInt64(
            "SELECT videoId FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, insertedFrameID)
            }
        )
        let storedFrameIndex = try await fetchInt64(
            "SELECT videoFrameIndex FROM frame WHERE id = ?;",
            bind: { statement in
                sqlite3_bind_int64(statement, 1, insertedFrameID)
            }
        )

        XCTAssertNil(storedEncodedAt)
        XCTAssertEqual(storedVideoID, insertedVideoID)
        XCTAssertEqual(storedFrameIndex, 7)
    }

    func testUpdateAndGetFrameMetadata() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/metadata-test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Metadata Test",
            browserUrl: "https://example.com",
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let insertedFrameID = try await database.insertFrame(frame)
        let frameID = FrameID(value: insertedFrameID)
        let metadataJSON = #"{"urls":[{"url":"https://example.com","nodeid":101,"position":{"x":0.1,"y":0.2,"width":0.3,"height":0.04},"nodetext":"example","domtext":"example","highlightstartindex":0,"highlightendindex":7,"confidence":0.9}],"mouseposition":{"x":12.0,"y":24.0},"videoposition":null}"#

        try await database.updateFrameMetadata(frameID: frameID, metadataJSON: metadataJSON)
        let stored = try await database.getFrameMetadata(frameID: frameID)

        XCTAssertEqual(stored, metadataJSON)
    }

    func testReplaceInPageURLData_AllowsNodeIDAboveInt32Max() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/in-page-url-large-node-id.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Large Node ID",
            browserUrl: "https://example.com",
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let insertedFrameID = try await database.insertFrame(frame)
        let frameID = FrameID(value: insertedFrameID)
        let largeNodeID = Int(Int32.max) + 1234

        let state = FrameInPageURLState(
            mouseX: 10.0,
            mouseY: 20.0,
            scrollX: 0.0,
            scrollY: 4500.0,
            videoCurrentTime: 42.5
        )
        let rows = [
            FrameInPageURLRow(
                order: 0,
                url: "https://example.com/path",
                nodeID: largeNodeID
            )
        ]

        try await database.replaceFrameInPageURLData(
            frameID: frameID,
            state: state,
            rows: rows
        )

        let storedRows = try await database.getFrameInPageURLRows(frameID: frameID)
        XCTAssertEqual(storedRows.count, 1)
        XCTAssertEqual(storedRows.first?.nodeID, largeNodeID)

        let storedState = try await database.getFrameInPageURLState(frameID: frameID)
        XCTAssertEqual(storedState, state)

        guard let db = await database.getConnection() else {
            XCTFail("Expected active database connection")
            return
        }

        let sql = "SELECT mousePosition, scrollPosition, videoCurrentTime FROM frame WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        sqlite3_bind_int64(statement, 1, frameID.value)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(statement, 0).map { String(cString: $0) }, "10.0,20.0")
        XCTAssertEqual(sqlite3_column_text(statement, 1).map { String(cString: $0) }, "0.0,4500.0")
        XCTAssertEqual(sqlite3_column_double(statement, 2), 42.5, accuracy: 0.0001)
    }

    func testReplaceInPageURLData_ReusesSharedURLTextAndCleansUpOrphans() async throws {
        let firstFrameID = try await insertTestFrame(browserURL: "https://example.com/a")
        let secondFrameID = try await insertTestFrame(browserURL: "https://example.com/b")

        let firstRows = [
            FrameInPageURLRow(
                order: 0,
                url: "/shared/path",
                nodeID: 101
            )
        ]
        let secondRows = [
            FrameInPageURLRow(
                order: 0,
                url: "/shared/path",
                nodeID: 202
            )
        ]

        try await database.replaceFrameInPageURLData(frameID: firstFrameID, state: nil, rows: firstRows)
        try await database.replaceFrameInPageURLData(frameID: secondFrameID, state: nil, rows: secondRows)

        let storedFirstRows = try await database.getFrameInPageURLRows(frameID: firstFrameID)
        let storedSecondRows = try await database.getFrameInPageURLRows(frameID: secondFrameID)
        XCTAssertEqual(storedFirstRows, firstRows)
        XCTAssertEqual(storedSecondRows, secondRows)

        let sharedURLTextCount = try await fetchInt64("SELECT COUNT(*) FROM in_page_url_text;")
        let distinctURLReferenceCount = try await fetchInt64(
            "SELECT COUNT(DISTINCT urlId) FROM frame_in_page_url;"
        )
        XCTAssertEqual(sharedURLTextCount, 1)
        XCTAssertEqual(distinctURLReferenceCount, 1)

        try await database.replaceFrameInPageURLData(frameID: firstFrameID, state: nil, rows: [])
        let countAfterFirstFrameRemoval = try await fetchInt64("SELECT COUNT(*) FROM in_page_url_text;")
        XCTAssertEqual(countAfterFirstFrameRemoval, 1)

        try await database.replaceFrameInPageURLData(frameID: secondFrameID, state: nil, rows: [])
        let countAfterSecondFrameRemoval = try await fetchInt64("SELECT COUNT(*) FROM in_page_url_text;")
        XCTAssertEqual(countAfterSecondFrameRemoval, 0)
    }

    func testReplaceInPageURLData_SkipsMalformedRowsAndDropsNonFiniteState() async throws {
        let frameID = try await insertTestFrame(browserURL: "https://example.com/malformed")

        let state = FrameInPageURLState(
            mouseX: .nan,
            mouseY: 24.0,
            scrollX: 0.0,
            scrollY: .infinity,
            videoCurrentTime: -.infinity
        )
        let rows = [
            FrameInPageURLRow(
                order: 0,
                url: "https://example.com/valid",
                nodeID: 100
            ),
            FrameInPageURLRow(
                order: 1,
                url: "https://example.com/nan",
                nodeID: 101
            ),
            FrameInPageURLRow(
                order: 2,
                url: "   ",
                nodeID: 102
            ),
            FrameInPageURLRow(
                order: 0,
                url: "https://example.com/duplicate-order",
                nodeID: 103
            )
        ]

        try await database.replaceFrameInPageURLData(frameID: frameID, state: state, rows: rows)

        let storedRows = try await database.getFrameInPageURLRows(frameID: frameID)
        XCTAssertEqual(
            storedRows,
            [
                FrameInPageURLRow(
                    order: 0,
                    url: "https://example.com/valid",
                    nodeID: 100
                ),
                FrameInPageURLRow(
                    order: 1,
                    url: "https://example.com/nan",
                    nodeID: 101
                )
            ]
        )

        let storedState = try await database.getFrameInPageURLState(frameID: frameID)
        XCTAssertNil(storedState)
    }

    func testEnsureInPageURLSchema_MigratesLegacyPerFrameRows() async throws {
        let frameID = try await insertTestFrame(browserURL: "https://example.com/legacy")
        let db = try await databaseConnection()

        try await executeRawSQL("""
            DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_row_def;
            DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;
            DROP TABLE IF EXISTS frame_in_page_url;
            DROP TABLE IF EXISTS in_page_url_row_def;
            DROP TABLE IF EXISTS in_page_url_text;
            CREATE TABLE frame_in_page_url (
                frameId INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                url TEXT NOT NULL,
                nid INTEGER NOT NULL,
                x REAL NOT NULL,
                y REAL NOT NULL,
                w REAL NOT NULL,
                h REAL NOT NULL,
                PRIMARY KEY (frameId, ord),
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE
            );
            """)

        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }

        let insertSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, url, nid, x, y, w, h)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil), SQLITE_OK)
        sqlite3_bind_int64(insertStatement, 1, frameID.value)
        sqlite3_bind_int64(insertStatement, 2, 0)
        sqlite3_bind_text(insertStatement, 3, "/legacy/shared", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insertStatement, 4, 77)
        sqlite3_bind_double(insertStatement, 5, 0.111)
        sqlite3_bind_double(insertStatement, 6, 0.222)
        sqlite3_bind_double(insertStatement, 7, 0.333)
        sqlite3_bind_double(insertStatement, 8, 0.044)
        XCTAssertEqual(sqlite3_step(insertStatement), SQLITE_DONE)

        try FrameQueries.ensureInPageURLSchema(db: db)

        let storedRows = try await database.getFrameInPageURLRows(frameID: frameID)
        XCTAssertEqual(storedRows.count, 1)
        XCTAssertEqual(storedRows.first?.url, "/legacy/shared")
        XCTAssertEqual(storedRows.first?.nodeID, 77)

        let migratedURLTextCount = try await fetchInt64("SELECT COUNT(*) FROM in_page_url_text;")
        let migratedFrameRowCount = try await fetchInt64("SELECT COUNT(*) FROM frame_in_page_url;")
        let legacyRowDefTableCount = try await fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'in_page_url_row_def';"
        )
        XCTAssertEqual(migratedURLTextCount, 1)
        XCTAssertEqual(migratedFrameRowCount, 1)
        XCTAssertEqual(legacyRowDefTableCount, 0)
    }

    func testEnsureInPageURLSchema_MigratesSharedRowDefinitionsToURLTextStorage() async throws {
        let firstFrameID = try await insertTestFrame(browserURL: "https://example.com/shared-a")
        let secondFrameID = try await insertTestFrame(browserURL: "https://example.com/shared-b")
        let db = try await databaseConnection()

        try await executeRawSQL("""
            DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_row_def;
            DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;
            DROP TABLE IF EXISTS frame_in_page_url;
            DROP TABLE IF EXISTS in_page_url_text;
            DROP TABLE IF EXISTS in_page_url_row_def;
            CREATE TABLE in_page_url_row_def (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                x1000 INTEGER NOT NULL,
                y1000 INTEGER NOT NULL,
                w1000 INTEGER NOT NULL,
                h1000 INTEGER NOT NULL,
                UNIQUE(url, x1000, y1000, w1000, h1000)
            );
            CREATE TABLE frame_in_page_url (
                frameId INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                rowDefId INTEGER NOT NULL,
                nid INTEGER NOT NULL,
                PRIMARY KEY (frameId, ord),
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE,
                FOREIGN KEY (rowDefId) REFERENCES in_page_url_row_def(id)
            );
            CREATE INDEX idx_frame_in_page_url_frameId
            ON frame_in_page_url(frameId);
            CREATE INDEX idx_frame_in_page_url_rowDefId
            ON frame_in_page_url(rowDefId);
            CREATE TRIGGER trg_frame_in_page_url_cleanup_row_def
            AFTER DELETE ON frame_in_page_url
            BEGIN
                DELETE FROM in_page_url_row_def
                WHERE id = OLD.rowDefId
                  AND NOT EXISTS (
                      SELECT 1
                      FROM frame_in_page_url
                      WHERE rowDefId = OLD.rowDefId
                  );
            END;
            """)

        var insertRowDefStatement: OpaquePointer?
        defer { sqlite3_finalize(insertRowDefStatement) }

        let insertRowDefSQL = """
            INSERT INTO in_page_url_row_def (url, x1000, y1000, w1000, h1000)
            VALUES (?, ?, ?, ?, ?);
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, insertRowDefSQL, -1, &insertRowDefStatement, nil), SQLITE_OK)

        sqlite3_bind_text(insertRowDefStatement, 1, "/shared/path", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insertRowDefStatement, 2, 125)
        sqlite3_bind_int64(insertRowDefStatement, 3, 250)
        sqlite3_bind_int64(insertRowDefStatement, 4, 375)
        sqlite3_bind_int64(insertRowDefStatement, 5, 50)
        XCTAssertEqual(sqlite3_step(insertRowDefStatement), SQLITE_DONE)
        let firstRowDefID = sqlite3_last_insert_rowid(db)

        sqlite3_reset(insertRowDefStatement)
        sqlite3_clear_bindings(insertRowDefStatement)
        sqlite3_bind_text(insertRowDefStatement, 1, "/shared/path", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insertRowDefStatement, 2, 625)
        sqlite3_bind_int64(insertRowDefStatement, 3, 500)
        sqlite3_bind_int64(insertRowDefStatement, 4, 250)
        sqlite3_bind_int64(insertRowDefStatement, 5, 80)
        XCTAssertEqual(sqlite3_step(insertRowDefStatement), SQLITE_DONE)
        let secondRowDefID = sqlite3_last_insert_rowid(db)

        var insertFrameRowStatement: OpaquePointer?
        defer { sqlite3_finalize(insertFrameRowStatement) }

        let insertFrameRowSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, rowDefId, nid)
            VALUES (?, ?, ?, ?);
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, insertFrameRowSQL, -1, &insertFrameRowStatement, nil), SQLITE_OK)

        sqlite3_bind_int64(insertFrameRowStatement, 1, firstFrameID.value)
        sqlite3_bind_int64(insertFrameRowStatement, 2, 0)
        sqlite3_bind_int64(insertFrameRowStatement, 3, firstRowDefID)
        sqlite3_bind_int64(insertFrameRowStatement, 4, 101)
        XCTAssertEqual(sqlite3_step(insertFrameRowStatement), SQLITE_DONE)

        sqlite3_reset(insertFrameRowStatement)
        sqlite3_clear_bindings(insertFrameRowStatement)
        sqlite3_bind_int64(insertFrameRowStatement, 1, secondFrameID.value)
        sqlite3_bind_int64(insertFrameRowStatement, 2, 0)
        sqlite3_bind_int64(insertFrameRowStatement, 3, secondRowDefID)
        sqlite3_bind_int64(insertFrameRowStatement, 4, 202)
        XCTAssertEqual(sqlite3_step(insertFrameRowStatement), SQLITE_DONE)

        try FrameQueries.ensureInPageURLSchema(db: db)

        let migratedFirstRows = try await database.getFrameInPageURLRows(frameID: firstFrameID)
        let migratedSecondRows = try await database.getFrameInPageURLRows(frameID: secondFrameID)
        XCTAssertEqual(migratedFirstRows.count, 1)
        XCTAssertEqual(migratedSecondRows.count, 1)
        XCTAssertEqual(migratedFirstRows.first?.url, "/shared/path")
        XCTAssertEqual(migratedSecondRows.first?.url, "/shared/path")
        XCTAssertEqual(migratedFirstRows.first?.nodeID, 101)
        XCTAssertEqual(migratedSecondRows.first?.nodeID, 202)

        let migratedURLTextCount = try await fetchInt64("SELECT COUNT(*) FROM in_page_url_text;")
        let migratedFrameRowCount = try await fetchInt64("SELECT COUNT(*) FROM frame_in_page_url;")
        let distinctURLReferenceCount = try await fetchInt64(
            "SELECT COUNT(DISTINCT urlId) FROM frame_in_page_url;"
        )
        let urlIDIndexCount = try await fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_frame_in_page_url_urlId';"
        )
        let frameIDIndexCount = try await fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_frame_in_page_url_frameId';"
        )
        let rowDefTableCount = try await fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'in_page_url_row_def';"
        )

        XCTAssertEqual(migratedURLTextCount, 1)
        XCTAssertEqual(migratedFrameRowCount, 2)
        XCTAssertEqual(distinctURLReferenceCount, 1)
        XCTAssertEqual(urlIDIndexCount, 1)
        XCTAssertEqual(frameIDIndexCount, 0)
        XCTAssertEqual(rowDefTableCount, 0)
    }

    func testMigrationRunner_V13RemovesRectColumnsFromExistingV12Table() async throws {
        let frameID = try await insertTestFrame(browserURL: "https://example.com/v12-upgrade")
        let db = try await databaseConnection()

        try await executeRawSQL("""
            DELETE FROM schema_migrations;
            INSERT INTO schema_migrations (version, applied_at) VALUES (12, 0);
            DROP TRIGGER IF EXISTS trg_frame_in_page_url_cleanup_text;
            DROP TABLE IF EXISTS frame_in_page_url;
            DROP TABLE IF EXISTS in_page_url_text;
            CREATE TABLE in_page_url_text (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL UNIQUE
            );
            CREATE TABLE frame_in_page_url (
                frameId INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                urlId INTEGER NOT NULL,
                nid INTEGER NOT NULL,
                x1000 INTEGER NOT NULL,
                y1000 INTEGER NOT NULL,
                w1000 INTEGER NOT NULL,
                h1000 INTEGER NOT NULL,
                PRIMARY KEY (frameId, ord),
                FOREIGN KEY (frameId) REFERENCES frame(id) ON DELETE CASCADE,
                FOREIGN KEY (urlId) REFERENCES in_page_url_text(id)
            );
            CREATE INDEX idx_frame_in_page_url_urlId
            ON frame_in_page_url(urlId);
            CREATE TRIGGER trg_frame_in_page_url_cleanup_text
            AFTER DELETE ON frame_in_page_url
            BEGIN
                DELETE FROM in_page_url_text
                WHERE id = OLD.urlId
                  AND NOT EXISTS (
                      SELECT 1
                      FROM frame_in_page_url
                      WHERE urlId = OLD.urlId
                  );
            END;
            INSERT INTO in_page_url_text (id, url)
            VALUES (1, '/v12/path');
            """)

        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }

        let insertSQL = """
            INSERT INTO frame_in_page_url (frameId, ord, urlId, nid, x1000, y1000, w1000, h1000)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil), SQLITE_OK)
        sqlite3_bind_int64(insertStatement, 1, frameID.value)
        sqlite3_bind_int64(insertStatement, 2, 0)
        sqlite3_bind_int64(insertStatement, 3, 1)
        sqlite3_bind_int64(insertStatement, 4, 321)
        sqlite3_bind_int64(insertStatement, 5, 125)
        sqlite3_bind_int64(insertStatement, 6, 250)
        sqlite3_bind_int64(insertStatement, 7, 375)
        sqlite3_bind_int64(insertStatement, 8, 50)
        XCTAssertEqual(sqlite3_step(insertStatement), SQLITE_DONE)

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        let currentVersion = try await fetchInt64("SELECT MAX(version) FROM schema_migrations;")
        let columnNames = try await tableColumnNames("frame_in_page_url")
        let storedRows = try await database.getFrameInPageURLRows(frameID: frameID)

        XCTAssertGreaterThanOrEqual(currentVersion, 13)
        XCTAssertTrue(columnNames.contains("frameId"))
        XCTAssertTrue(columnNames.contains("ord"))
        XCTAssertTrue(columnNames.contains("urlId"))
        XCTAssertTrue(columnNames.contains("nid"))
        XCTAssertFalse(columnNames.contains("x1000"))
        XCTAssertFalse(columnNames.contains("y1000"))
        XCTAssertFalse(columnNames.contains("w1000"))
        XCTAssertFalse(columnNames.contains("h1000"))
        XCTAssertEqual(
            storedRows,
            [FrameInPageURLRow(order: 0, url: "/v12/path", nodeID: 321)]
        )
    }

    func testMigrationRunner_V16AddsProcessingQueueRewrittenAndDocSegmentIndexes() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceV16Migration-\(UUID().uuidString).sqlite")
            .path
        let db = try openRawDatabase(at: dbPath)

        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        try await runLegacyMigrations(throughVersion: 15, db: db)

        let preMigrationIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_processing_queue_frameid';",
            db: db
        )
        let preMigrationRewrittenIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_frame_rewritten_at';",
            db: db
        )
        let preMigrationDocSegmentIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'index_doc_segment_on_docid_frameid';",
            db: db
        )
        XCTAssertEqual(preMigrationIndexCount, 0)
        XCTAssertEqual(preMigrationRewrittenIndexCount, 0)
        XCTAssertEqual(preMigrationDocSegmentIndexCount, 0)

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        let currentVersion = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        let processingQueueIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_processing_queue_frameid';",
            db: db
        )
        let rewrittenIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_frame_rewritten_at';",
            db: db
        )
        let docSegmentIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'index_doc_segment_on_docid_frameid';",
            db: db
        )

        XCTAssertGreaterThanOrEqual(currentVersion, 16)
        XCTAssertEqual(processingQueueIndexCount, 1)
        XCTAssertEqual(rewrittenIndexCount, 1)
        XCTAssertEqual(docSegmentIndexCount, 1)
    }

    func testMigrationRunner_V17AddsCaptureTriggerColumn() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceV17Migration-\(UUID().uuidString).sqlite")
            .path
        let db = try openRawDatabase(at: dbPath)

        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        try executeRawSQL(Schema.createSchemaMigrationsTable, db: db)
        try executeRawSQL(
            """
            CREATE TABLE frame (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                imagePath TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                segmentId INTEGER NOT NULL,
                videoId INTEGER,
                ocrText TEXT,
                imageWidth INTEGER NOT NULL,
                imageHeight INTEGER NOT NULL,
                isRedacted BOOLEAN DEFAULT 0,
                redactionConfidence REAL,
                processingStatus INTEGER DEFAULT 0,
                processedAt INTEGER,
                redactionReason INTEGER,
                metadata TEXT,
                mousePosition TEXT,
                scrollPosition TEXT,
                videoCurrentTime REAL,
                rewritePurpose INTEGER,
                rewrittenAt INTEGER
            );
            """,
            db: db
        )
        try executeRawSQL(
            """
            CREATE TABLE daily_metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                metricType INTEGER NOT NULL,
                value INTEGER NOT NULL DEFAULT 0,
                metadata TEXT
            );
            """,
            db: db
        )
        try executeRawSQL(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (16, \(Int64(Date().timeIntervalSince1970 * 1_000)));",
            db: db
        )

        var preMigrationStatement: OpaquePointer?
        defer { sqlite3_finalize(preMigrationStatement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(frame);", -1, &preMigrationStatement, nil), SQLITE_OK)

        var preMigrationColumns: [String] = []
        while sqlite3_step(preMigrationStatement) == SQLITE_ROW {
            if let name = sqlite3_column_text(preMigrationStatement, 1).map({ String(cString: $0) }) {
                preMigrationColumns.append(name)
            }
        }
        XCTAssertFalse(preMigrationColumns.contains("capture_trigger"))

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        var postMigrationStatement: OpaquePointer?
        defer { sqlite3_finalize(postMigrationStatement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(frame);", -1, &postMigrationStatement, nil), SQLITE_OK)

        var postMigrationColumns: [String] = []
        while sqlite3_step(postMigrationStatement) == SQLITE_ROW {
            if let name = sqlite3_column_text(postMigrationStatement, 1).map({ String(cString: $0) }) {
                postMigrationColumns.append(name)
            }
        }

        let currentVersion = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        XCTAssertGreaterThanOrEqual(currentVersion, 17)
        XCTAssertTrue(postMigrationColumns.contains("capture_trigger"))
    }

    func testMigrationRunner_V19AddsEncodedAtWithoutBackfillingExistingFrames() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceV19Migration-\(UUID().uuidString).sqlite")
            .path
        let db = try openRawDatabase(at: dbPath)

        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        let createdAtMs: Int64 = 1_700_000_000_000
        try await runLegacyMigrations(throughVersion: 18, db: db)

        let preMigrationColumns = try tableColumnNames("frame", db: db)
        let preMigrationLegacyIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'index_frame_on_encodingstatus_createdat';",
            db: db
        )

        XCTAssertFalse(preMigrationColumns.contains("encodedAt"))
        XCTAssertEqual(preMigrationLegacyIndexCount, 1)

        try executeRawSQL(
            """
            INSERT INTO frame (id, createdAt, imageFileName, processingStatus)
            VALUES (1, \(createdAtMs), 'legacy-frame.jpg', 0);
            """,
            db: db
        )

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        let currentVersion = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        let encodedAtNullCount = try fetchInt64(
            "SELECT COUNT(*) FROM frame WHERE id = 1 AND encodedAt IS NULL;",
            db: db
        )
        let encodedAtIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_frame_encoded_at';",
            db: db
        )
        let legacyIndexCount = try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'index_frame_on_encodingstatus_createdat';",
            db: db
        )

        XCTAssertGreaterThanOrEqual(currentVersion, 19)
        XCTAssertEqual(encodedAtNullCount, 1)
        XCTAssertEqual(encodedAtIndexCount, 1)
        XCTAssertEqual(legacyIndexCount, 0)
    }

    func testGetPendingFrameIDsNotInQueueReturnsOnlyNewestOrphanedFrames() async throws {
        let oldestFrame = try await insertTestFrame(
            browserURL: "https://example.com/oldest",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let queuedFrame = try await insertTestFrame(
            browserURL: "https://example.com/queued",
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        let newestFrame = try await insertTestFrame(
            browserURL: "https://example.com/newest",
            timestamp: Date(timeIntervalSince1970: 3_000)
        )

        try await executeRawSQL(
            "UPDATE frame SET processingStatus = 0 WHERE id IN (\(oldestFrame.value), \(queuedFrame.value), \(newestFrame.value));"
        )
        try await database.enqueueFrameForProcessing(frameID: queuedFrame.value, priority: 0)

        let orphanedFrameIDs = try await database.getPendingFrameIDsNotInQueue(limit: 10)
        let orphanedCount = try await database.countPendingFramesNotInQueue()

        XCTAssertEqual(orphanedFrameIDs, [newestFrame.value, oldestFrame.value])
        XCTAssertEqual(orphanedCount, 2)
    }

    func testGetFramesByTimeRange() async throws {
        let startTime = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(600),
            frameCount: 3,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        try await database.insertVideoSegment(videoSegment)

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: startTime,
            endDate: startTime.addingTimeInterval(600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let now = Date()

        // Insert frames at different times
        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-600), // 10 min ago
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-300), // 5 min ago
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 1,
            metadata: .empty,
            source: .native
        )

        let frame3 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now, // now
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 2,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)
        try await database.insertFrame(frame3)

        // Query for frames in a range
        let startDate = now.addingTimeInterval(-400) // 6.7 min ago
        let endDate = now.addingTimeInterval(100)     // future
        let frames = try await database.getFrames(from: startDate, to: endDate, limit: 10)

        // Should get frame2 and frame3
        XCTAssertEqual(frames.count, 2)
    }

    func testGetFramesByApp() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let timestamp = Date()

        // Create Safari app segment
        let safariSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create Xcode app segment
        let xcodeSegmentID = try await database.insertSegment(
            bundleID: "com.apple.Xcode",
            startDate: timestamp.addingTimeInterval(300),
            endDate: timestamp.addingTimeInterval(600),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: safariSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.apple.Safari"),
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(300),
            segmentID: AppSegmentID(value: xcodeSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            metadata: FrameMetadata(appBundleID: "com.apple.Xcode"),
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        let safariFrames = try await database.getFrames(
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(safariFrames.count, 1)
        XCTAssertEqual(safariFrames.first?.metadata.appBundleID, "com.apple.Safari")
    }

    func testDeleteOldFrames() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(600),
            frameCount: 2,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let now = Date()

        // Create app segment for old frame
        let oldAppSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now.addingTimeInterval(-86400 * 100),
            endDate: now.addingTimeInterval(-86400 * 100 + 300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create app segment for recent frame
        let recentAppSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: now,
            endDate: now.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let oldFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-86400 * 100), // 100 days ago
            segmentID: AppSegmentID(value: oldAppSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let recentFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: now,
            segmentID: AppSegmentID(value: recentAppSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(oldFrame)
        try await database.insertFrame(recentFrame)

        // Delete frames older than 30 days
        let cutoffDate = now.addingTimeInterval(-86400 * 30)
        let deletedCount = try await database.deleteFrames(olderThan: cutoffDate)

        XCTAssertEqual(deletedCount, 1)

        // Verify only recent frame remains
        let remainingCount = try await database.getFrameCount()
        XCTAssertEqual(remainingCount, 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ STATISTICS TESTS                                                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetStatistics() async throws {
        // Create some test data
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 2,
            fileSizeBytes: 1024 * 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        _ = try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame1 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(100),
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            metadata: .empty,
            source: .native
        )

        try await database.insertFrame(frame1)
        try await database.insertFrame(frame2)

        // Get statistics
        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.frameCount, 2)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertNotNil(stats.oldestFrameDate)
        XCTAssertNotNil(stats.newestFrameDate)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ CASCADE DELETE TESTS                                                    │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testCascadeDeleteSegmentRemovesFrames() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(segment)

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )
        let insertedFrameID = try await database.insertFrame(frame)

        // Verify frame exists
        var retrievedFrame = try await database.getFrame(id: FrameID(value: insertedFrameID))
        XCTAssertNotNil(retrievedFrame)
        XCTAssertEqual(retrievedFrame?.videoID.value, insertedVideoID)

        // Deleting a video segment should preserve frame rows and null out frame.videoId.
        try await database.deleteVideoSegment(id: VideoSegmentID(value: insertedVideoID))

        // Verify frame still exists but is no longer linked to a video.
        retrievedFrame = try await database.getFrame(id: FrameID(value: insertedFrameID))
        XCTAssertNotNil(retrievedFrame)
        XCTAssertEqual(retrievedFrame?.videoID.value, 0)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ SEGMENT COMMENT TESTS                                                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSegmentComment_CanLinkToMultipleSegments() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.b")

        let comment = try await database.createSegmentComment(
            body: "Investigation notes",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        let commentsForA = try await database.getCommentsForSegment(segmentId: segmentA)
        let commentsForB = try await database.getCommentsForSegment(segmentId: segmentB)
        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)

        XCTAssertEqual(commentsForA.count, 1)
        XCTAssertEqual(commentsForB.count, 1)
        XCTAssertEqual(commentsForA.first?.id, comment.id)
        XCTAssertEqual(commentsForB.first?.id, comment.id)
        XCTAssertEqual(linkedSegmentCount, 2)
    }

    func testSegmentComment_PersistsFrameAnchor() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(60),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/comment-anchor.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = try await database.insertVideoSegment(videoSegment)

        let segmentID = try await database.insertSegment(
            bundleID: "com.test.anchor",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Anchor Window",
            browserUrl: nil,
            type: 0
        )
        let segment = SegmentID(value: segmentID)

        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                metadata: .empty,
                source: .native
            )
        )
        let frameID = FrameID(value: insertedFrameID)

        let comment = try await database.createSegmentComment(
            body: "Anchored to frame",
            author: "Test User",
            attachments: [],
            frameID: frameID
        )
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        let comments = try await database.getCommentsForSegment(segmentId: segment)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.frameID?.value, insertedFrameID)
    }

    func testSegmentComment_FallbackNavigationResolvers() async throws {
        let timestamp = Date()
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 4,
            fileSizeBytes: 2048,
            relativePath: "segments/comment-fallback.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = try await database.insertVideoSegment(videoSegment)

        let segmentAID = try await database.insertSegment(
            bundleID: "com.test.fallback.a",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(30),
            windowName: "Fallback A",
            browserUrl: nil,
            type: 0
        )
        let segmentBID = try await database.insertSegment(
            bundleID: "com.test.fallback.b",
            startDate: timestamp.addingTimeInterval(31),
            endDate: timestamp.addingTimeInterval(60),
            windowName: "Fallback B",
            browserUrl: nil,
            type: 0
        )
        let segmentA = SegmentID(value: segmentAID)
        let segmentB = SegmentID(value: segmentBID)

        let firstFrameInA = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(1),
                segmentID: AppSegmentID(value: segmentAID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                metadata: .empty,
                source: .native
            )
        )
        _ = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(2),
                segmentID: AppSegmentID(value: segmentAID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 1,
                metadata: .empty,
                source: .native
            )
        )
        _ = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp.addingTimeInterval(35),
                segmentID: AppSegmentID(value: segmentBID),
                videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: 0,
                metadata: .empty,
                source: .native
            )
        )

        let comment = try await database.createSegmentComment(
            body: "No frame anchor; fallback should use first frame in linked segment",
            author: "Test User",
            attachments: [],
            frameID: nil
        )
        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        let resolvedSegment = try await database.getFirstLinkedSegmentForComment(commentId: comment.id)
        XCTAssertEqual(resolvedSegment, segmentA)

        let resolvedFrame = try await database.getFirstFrameForSegment(segmentId: segmentA)
        XCTAssertEqual(resolvedFrame?.value, firstFrameInA)
    }

    func testSegmentComment_GetCommentsForSegments_DeduplicatesAndUsesRequestedSegmentOrder() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.batch.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.batch.b")
        let segmentC = try await insertTestAppSegment(bundleID: "com.test.batch.c")

        let sharedComment = try await database.createSegmentComment(
            body: "Shared across A and C",
            author: "Test User",
            attachments: []
        )
        let onlyBComment = try await database.createSegmentComment(
            body: "Only on B",
            author: "Test User",
            attachments: []
        )
        let onlyAComment = try await database.createSegmentComment(
            body: "Only on A",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: sharedComment.id)
        try await database.addCommentToSegment(segmentId: segmentC, commentId: sharedComment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: onlyBComment.id)
        try await database.addCommentToSegment(segmentId: segmentA, commentId: onlyAComment.id)

        let linkedComments = try await database.getCommentsForSegments(
            segmentIds: [segmentB, segmentC, segmentA, segmentC]
        )

        XCTAssertEqual(linkedComments.count, 3)
        XCTAssertEqual(linkedComments.map(\.comment.id), [sharedComment.id, onlyBComment.id, onlyAComment.id])

        let preferredSegmentByCommentID = Dictionary(
            uniqueKeysWithValues: linkedComments.map { ($0.comment.id, $0.preferredSegmentID) }
        )
        XCTAssertEqual(preferredSegmentByCommentID[sharedComment.id], segmentC)
        XCTAssertEqual(preferredSegmentByCommentID[onlyBComment.id], segmentB)
        XCTAssertEqual(preferredSegmentByCommentID[onlyAComment.id], segmentA)
    }

    func testSegmentComment_SearchReturnsMatches() async throws {
        let matching = try await database.createSegmentComment(
            body: "Investigate crash in sidebar panel",
            author: "Test User",
            attachments: []
        )
        _ = try await database.createSegmentComment(
            body: "Misc unrelated note",
            author: "Test User",
            attachments: []
        )

        let results = try await database.searchSegmentComments(
            query: "crash side",
            limit: 20
        )

        XCTAssertTrue(results.contains(where: { $0.id == matching.id }))
        XCTAssertFalse(results.contains(where: { $0.body == "Misc unrelated note" }))
    }

    func testSegmentComment_SearchHonorsLimitCap() async throws {
        for index in 0..<15 {
            _ = try await database.createSegmentComment(
                body: "Cap limit phrase \(index)",
                author: "Test User",
                attachments: []
            )
        }

        let results = try await database.searchSegmentComments(
            query: "cap limit",
            limit: 5
        )

        XCTAssertEqual(results.count, 5)
    }

    func testSegmentComment_SearchSupportsOffsetPagination() async throws {
        for index in 0..<15 {
            _ = try await database.createSegmentComment(
                body: "Paged phrase \(index)",
                author: "Test User",
                attachments: []
            )
        }

        let firstPage = try await database.searchSegmentComments(
            query: "paged phrase",
            limit: 10,
            offset: 0
        )
        let secondPage = try await database.searchSegmentComments(
            query: "paged phrase",
            limit: 10,
            offset: 10
        )

        XCTAssertEqual(firstPage.count, 10)
        XCTAssertEqual(secondPage.count, 5)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
    }

    func testSegmentComment_DuplicateLinkIsIgnored() async throws {
        let segment = try await insertTestAppSegment(bundleID: "com.test.duplicate")
        let comment = try await database.createSegmentComment(
            body: "Same link twice",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        XCTAssertEqual(linkedSegmentCount, 1)
    }

    func testDeleteSegment_RemovesOnlyThatSegmentLink_ForSharedComment() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.shared.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.shared.b")

        let comment = try await database.createSegmentComment(
            body: "Shared across segments",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)

        try await database.deleteSegment(id: segmentA.value)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        let commentsForB = try await database.getCommentsForSegment(segmentId: segmentB)

        XCTAssertEqual(linkedSegmentCount, 1)
        XCTAssertEqual(commentsForB.count, 1)
        XCTAssertEqual(commentsForB.first?.id, comment.id)
    }

    func testRemoveCommentFromLastSegment_DeletesOrphanComment() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.orphan.a")

        let comment = try await database.createSegmentComment(
            body: "Will become orphan",
            author: "Test User",
            attachments: []
        )
        try await database.addCommentToSegment(segmentId: segmentA, commentId: comment.id)

        try await database.removeCommentFromSegment(segmentId: segmentA, commentId: comment.id)

        let linkedSegmentCount = try await database.getSegmentCountForComment(commentId: comment.id)
        XCTAssertEqual(linkedSegmentCount, 0)

        let segmentB = try await insertTestAppSegment(bundleID: "com.test.orphan.b")
        do {
            try await database.addCommentToSegment(segmentId: segmentB, commentId: comment.id)
            XCTFail("Expected linking an orphan-deleted comment to fail")
        } catch {
            // Expected: FK violation because orphan cleanup deleted the comment row.
        }
    }

    func testDeleteSegment_DeletesOrphanCommentAttachments() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceCommentAttachmentTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let attachmentURL = tempDir.appendingPathComponent("note.txt")
        try Data("attachment-body".utf8).write(to: attachmentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

        let segment = try await insertTestAppSegment(bundleID: "com.test.attachment")
        let comment = try await database.createSegmentComment(
            body: "Has file",
            author: "Test User",
            attachments: [
                SegmentCommentAttachment(
                    filePath: attachmentURL.path,
                    fileName: "note.txt",
                    mimeType: "text/plain",
                    sizeBytes: 15
                )
            ]
        )
        try await database.addCommentToSegment(segmentId: segment, commentId: comment.id)

        try await database.deleteSegment(id: segment.value)

        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))

        let anotherSegment = try await insertTestAppSegment(bundleID: "com.test.attachment.b")
        do {
            try await database.addCommentToSegment(segmentId: anotherSegment, commentId: comment.id)
            XCTFail("Expected deleted orphan comment to be unavailable for relinking")
        } catch {
            // Expected.
        }
    }

    func testGetFrameWithVideoInfoByID_UsesConfiguredStorageRootForRelativeVideoPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceFrameVideoPathTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dbPath = tempDir.appendingPathComponent("retrace.db").path
        let customDatabase = DatabaseManager(
            databasePath: dbPath,
            storageRootPath: tempDir.path
        )
        do {
            try await customDatabase.initialize()

            let timestamp = Date(timeIntervalSince1970: 1_741_700_000)
            let videoID = try await customDatabase.insertVideoSegment(
                VideoSegment(
                    id: VideoSegmentID(value: 0),
                    startTime: timestamp,
                    endTime: timestamp.addingTimeInterval(60),
                    frameCount: 1,
                    fileSizeBytes: 1024,
                    relativePath: "chunks/202603/12/1234.mp4",
                    width: 1920,
                    height: 1080,
                    source: .native
                )
            )
            let segmentID = try await customDatabase.insertSegment(
                bundleID: "com.test.video-path",
                startDate: timestamp,
                endDate: timestamp.addingTimeInterval(60),
                windowName: "Window",
                browserUrl: nil,
                type: 0
            )
            let frameID = try await customDatabase.insertFrame(
                FrameReference(
                    id: FrameID(value: 0),
                    timestamp: timestamp,
                    segmentID: AppSegmentID(value: segmentID),
                    videoID: VideoSegmentID(value: videoID),
                    frameIndexInSegment: 0,
                    metadata: .empty,
                    source: .native
                )
            )

            try await customDatabase.replaceFrameInPageURLData(
                frameID: FrameID(value: frameID),
                state: FrameInPageURLState(
                    mouseX: 321.25,
                    mouseY: 654.75,
                    scrollX: nil,
                    scrollY: nil,
                    videoCurrentTime: nil
                ),
                rows: []
            )

            let frameWithVideoInfo = try await customDatabase.getFrameWithVideoInfoByID(
                id: FrameID(value: frameID)
            )
            let frame = try XCTUnwrap(frameWithVideoInfo)
            let videoInfo = try XCTUnwrap(frame.videoInfo)

            XCTAssertEqual(
                videoInfo.videoPath,
                tempDir.appendingPathComponent("chunks/202603/12/1234.mp4").path
            )
            XCTAssertEqual(Double(frame.frame.metadata.mousePosition?.x ?? 0), 321.25, accuracy: 0.0001)
            XCTAssertEqual(Double(frame.frame.metadata.mousePosition?.y ?? 0), 654.75, accuracy: 0.0001)

            try await customDatabase.close()
        } catch {
            try? await customDatabase.close()
            throw error
        }
    }

    func testDeleteSegment_DeletesRelativeCommentAttachmentsUsingConfiguredStorageRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceRelativeAttachmentTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let attachmentsDir = tempDir.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let relativeAttachmentPath = "attachments/note.txt"
        let attachmentURL = tempDir.appendingPathComponent(relativeAttachmentPath)
        try Data("attachment-body".utf8).write(to: attachmentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

        let dbPath = tempDir.appendingPathComponent("retrace.db").path
        let customDatabase = DatabaseManager(
            databasePath: dbPath,
            storageRootPath: tempDir.path
        )
        do {
            try await customDatabase.initialize()

            let segment = try await customDatabase.insertSegment(
                bundleID: "com.test.relative-attachment",
                startDate: Date(),
                endDate: Date().addingTimeInterval(30),
                windowName: "Test Window",
                browserUrl: nil,
                type: 0
            )
            let comment = try await customDatabase.createSegmentComment(
                body: "Has relative file",
                author: "Test User",
                attachments: [
                    SegmentCommentAttachment(
                        filePath: relativeAttachmentPath,
                        fileName: "note.txt",
                        mimeType: "text/plain",
                        sizeBytes: 15
                    )
                ]
            )
            try await customDatabase.addCommentToSegment(segmentId: SegmentID(value: segment), commentId: comment.id)

            try await customDatabase.deleteSegment(id: segment)

            XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))

            try await customDatabase.close()
        } catch {
            try? await customDatabase.close()
            throw error
        }
    }

    func testSegmentComment_GetSegmentCommentCountsMap() async throws {
        let segmentA = try await insertTestAppSegment(bundleID: "com.test.counts.a")
        let segmentB = try await insertTestAppSegment(bundleID: "com.test.counts.b")

        let commentA = try await database.createSegmentComment(
            body: "A",
            author: "Test User",
            attachments: []
        )
        let commentB = try await database.createSegmentComment(
            body: "B",
            author: "Test User",
            attachments: []
        )

        try await database.addCommentToSegment(segmentId: segmentA, commentId: commentA.id)
        try await database.addCommentToSegment(segmentId: segmentA, commentId: commentB.id)
        try await database.addCommentToSegment(segmentId: segmentB, commentId: commentB.id)

        let map = try await database.getSegmentCommentCountsMap()

        XCTAssertEqual(map[segmentA.value], 2)
        XCTAssertEqual(map[segmentB.value], 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ PROCESSING QUEUE TESTS                                                 │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testDequeueFrameForProcessingMarksFrameProcessingAtomically() async throws {
        let frameID = try await insertTestFrame(browserURL: nil).value
        let pendingStatus = 0
        let processingStatus = 1

        try await database.updateFrameProcessingStatus(
            frameID: frameID,
            status: pendingStatus
        )
        try await database.enqueueFrameForProcessing(frameID: frameID)

        let pendingOrphansBeforeDequeue = try await database.countPendingFramesNotInQueue()
        let queuedRowCountBeforeDequeue = try await fetchInt64(
            "SELECT COUNT(*) FROM processing_queue WHERE frameId = ?;",
            bind: { sqlite3_bind_int64($0, 1, frameID) }
        )

        XCTAssertEqual(pendingOrphansBeforeDequeue, 0)
        XCTAssertEqual(queuedRowCountBeforeDequeue, 1)

        let dequeued = try await database.dequeueFrameForProcessing()
        let frameStatusAfterDequeue = try await database.getFrameProcessingStatus(frameID: frameID)
        let queuedRowCountAfterDequeue = try await fetchInt64(
            "SELECT COUNT(*) FROM processing_queue WHERE frameId = ?;",
            bind: { sqlite3_bind_int64($0, 1, frameID) }
        )
        let pendingOrphansAfterDequeue = try await database.countPendingFramesNotInQueue()

        XCTAssertEqual(dequeued?.frameID, frameID)
        XCTAssertEqual(frameStatusAfterDequeue, processingStatus)
        XCTAssertEqual(queuedRowCountAfterDequeue, 0)
        XCTAssertEqual(pendingOrphansAfterDequeue, 0)

        let crashedFrames = try await database.getCrashedProcessingFrameIDs()
        XCTAssertTrue(crashedFrames.contains(frameID))
    }

    // MARK: - Helpers

    private func insertTestAppSegment(bundleID: String) async throws -> SegmentID {
        let start = Date()
        let id = try await database.insertSegment(
            bundleID: bundleID,
            startDate: start,
            endDate: start.addingTimeInterval(30),
            windowName: "Test Window",
            browserUrl: nil,
            type: 0
        )
        return SegmentID(value: id)
    }

    private func insertTestFrame(
        browserURL: String?,
        bundleID: String = "com.apple.Safari",
        timestamp: Date = Date()
    ) async throws -> FrameID {
        let videoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: timestamp,
            endTime: timestamp.addingTimeInterval(120),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "segments/test-\(UUID().uuidString).mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let insertedVideoID = try await database.insertVideoSegment(videoSegment)
        let appSegmentID = try await database.insertSegment(
            bundleID: bundleID,
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Test Window",
            browserUrl: browserURL,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: VideoSegmentID(value: insertedVideoID),
            frameIndexInSegment: 0,
            metadata: .empty,
            source: .native
        )

        return FrameID(value: try await database.insertFrame(frame))
    }

    private func insertTestFrame(
        videoID: Int64,
        segmentID: Int64,
        frameIndex: Int,
        timestamp: Date,
        bundleID: String = "com.apple.Safari",
        browserURL: String? = nil
    ) async throws -> FrameID {
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: segmentID),
            videoID: VideoSegmentID(value: videoID),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test",
                windowName: "Test Window",
                browserURL: browserURL
            ),
            source: .native
        )

        return FrameID(value: try await database.insertFrame(frame))
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: 0
            )
        )!
    }

    private func localDayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func databaseConnection() async throws -> OpaquePointer {
        guard let db = await database.getConnection() else {
            throw NSError(domain: "DatabaseManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected active database connection"])
        }
        return db
    }

    private func executeRawSQL(_ sql: String) async throws {
        let db = try await databaseConnection()
        try executeRawSQL(sql, db: db)
    }

    private func executeRawSQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            throw NSError(domain: "DatabaseManagerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func fetchInt64(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) async throws -> Int64 {
        let db = try await databaseConnection()
        return try fetchInt64(sql, db: db, bind: bind)
    }

    private func fetchInt64(
        _ sql: String,
        db: OpaquePointer,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseManagerTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        bind?(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "DatabaseManagerTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Expected one row for query: \(sql)"])
        }

        return sqlite3_column_int64(statement, 0)
    }

    private func fetchText(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) async throws -> String? {
        let db = try await databaseConnection()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseManagerTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        bind?(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "DatabaseManagerTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Expected one row for query: \(sql)"])
        }

        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func tableColumnNames(_ table: String) async throws -> [String] {
        let db = try await databaseConnection()
        return try tableColumnNames(table, db: db)
    }

    private func tableColumnNames(_ table: String, db: OpaquePointer) throws -> [String] {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseManagerTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        var columnNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) {
                columnNames.append(name)
            }
        }

        return columnNames
    }

    private func openRawDatabase(at path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open raw database"
            sqlite3_close(db)
            throw NSError(domain: "DatabaseManagerTests", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
        }

        try executeRawSQL("PRAGMA foreign_keys = ON;", db: db)
        try executeRawSQL("PRAGMA journal_mode = WAL;", db: db)
        try executeRawSQL("PRAGMA synchronous = NORMAL;", db: db)
        return db
    }

    private func removeSQLiteTestArtifacts(atPath path: String) {
        removeFileIfPresent(atPath: path)
        removeFileIfPresent(atPath: path + "-wal")
        removeFileIfPresent(atPath: path + "-shm")
    }

    private func removeFileIfPresent(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            return
        } catch {
            XCTFail("Failed to remove test artifact at \(path): \(error)")
        }
    }

    private func runLegacyMigrations(throughVersion version: Int, db: OpaquePointer) async throws {
        try executeRawSQL(Schema.createSchemaMigrationsTable, db: db)

        let migrations: [Migration] = [
            V1_InitialSchema(),
            V2_UnfinalisedVideoTracking(),
            V3_TagSystem(),
            V4_DailyMetrics(),
            V5_FTSUnicode61(),
            V6_FrameProcessedAt(),
            V7_FrameRedactionReason(),
            V8_SegmentComments(),
            V9_SegmentCommentFrameAnchor(),
            V10_SegmentCommentSearchIndex(),
            V11_SegmentCommentLinkCompositeIndex(),
            V12_FrameMetadata(),
            V13_RemoveInPageURLRects(),
            V14_DBStorageSnapshot(),
            V15_NodeRedactionFlag(),
            V16_ProcessingQueueFrameIDIndex(),
            V17_FrameCaptureTrigger(),
            V18_DailyMetricsRecencyIndex()
        ]

        for migration in migrations where migration.version <= version {
            try await migration.migrate(db: db)
            try executeRawSQL(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (\(migration.version), \(Int64(Date().timeIntervalSince1970 * 1_000)));",
                db: db
            )
        }
    }
}
