import XCTest
import Foundation
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
            encodingStatus: .success,
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
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "Retrace - GitHub",
                browserURL: "https://github.com/retrace"
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
            encodingStatus: .success,
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
            encodingStatus: .success,
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

        XCTAssertEqual(currentVersion, 13)
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
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now.addingTimeInterval(-300), // 5 min ago
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame3 = FrameReference(
            id: FrameID(value: 0),
            timestamp: now, // now
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoSegment.id,
            frameIndexInSegment: 2,
            encodingStatus: .success,
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
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.apple.Safari"),
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(300),
            segmentID: AppSegmentID(value: xcodeSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
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
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let recentFrame = FrameReference(
            id: FrameID(value: 0),
            timestamp: now,
            segmentID: AppSegmentID(value: recentAppSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
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
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let frame2 = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp.addingTimeInterval(100),
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: segment.id,
            frameIndexInSegment: 1,
            encodingStatus: .success,
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
            encodingStatus: .success,
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
                encodingStatus: .success,
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
                encodingStatus: .success,
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
                encodingStatus: .success,
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
                encodingStatus: .success,
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
                    encodingStatus: .success,
                    metadata: .empty,
                    source: .native
                )
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
        bundleID: String = "com.apple.Safari"
    ) async throws -> FrameID {
        let timestamp = Date()
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
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        return FrameID(value: try await database.insertFrame(frame))
    }

    private func databaseConnection() async throws -> OpaquePointer {
        guard let db = await database.getConnection() else {
            throw NSError(domain: "DatabaseManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected active database connection"])
        }
        return db
    }

    private func executeRawSQL(_ sql: String) async throws {
        let db = try await databaseConnection()
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

    private func tableColumnNames(_ table: String) async throws -> [String] {
        let db = try await databaseConnection()
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
}
