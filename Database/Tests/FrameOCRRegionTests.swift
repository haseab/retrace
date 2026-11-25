import Foundation
import XCTest
import SQLCipher
import Shared
@testable import Database

final class FrameOCRRegionTests: XCTestCase {
    func testLegacyFrameMetadataRemainsDecodable() throws {
        let legacy = Data(#"{"displayID":42,"redactionReason":"private window","captureTrigger":"mouse"}"#.utf8)
        let metadata = try JSONDecoder().decode(FrameMetadata.self, from: legacy)
        XCTAssertTrue(metadata.isFocused)
        XCTAssertEqual(metadata.displayID, 42)
        XCTAssertEqual(metadata.redactionReason, "private window")
        XCTAssertEqual(metadata.captureTrigger, .mouse)
    }

    func testV20UpgradeKeepsPrivacyMetadataAndAddsLegacyDisplayDefaults() async throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        let oldSchema = """
            CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER);
            INSERT INTO schema_migrations VALUES(20, 1000);
            CREATE TABLE frame(id INTEGER PRIMARY KEY, createdAt INTEGER, redactionReason TEXT,
                               capture_trigger TEXT, encodedAt INTEGER);
            CREATE TABLE video(id INTEGER PRIMARY KEY, width INTEGER, height INTEGER, processingState INTEGER);
            INSERT INTO frame VALUES(1, 1000, 'private window', 'mouse', 1200);
            INSERT INTO video VALUES(1, 1920, 1080, 1);
            """
        XCTAssertEqual(sqlite3_exec(db, oldSchema, nil, nil, nil), SQLITE_OK)
        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()
        try await runner.runMigrations()
        let version = try await runner.getCurrentVersion()
        XCTAssertEqual(version, 21)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT displayID,isFocused,redactionReason,capture_trigger,encodedAt FROM frame WHERE id=1", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        XCTAssertEqual(sqlite3_column_int(statement, 1), 1)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 2)), "private window")
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 3)), "mouse")
        XCTAssertEqual(sqlite3_column_int(statement, 4), 1200)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO display VALUES(42,'Example display',1000); INSERT INTO display_session(displayID,connectedAt) VALUES(42,1000)", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "INSERT INTO display_session(displayID,connectedAt) VALUES(42,1001)", nil, nil, nil), SQLITE_OK)
    }

    func testDisplayFieldsRoundTripAlongsidePrivacyAndCaptureTrigger() async throws {
        let database = DatabaseManager(databasePath: "file:display_fields_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'com.example.editor',0,10000,0)", nil, nil, nil), SQLITE_OK)
        let metadata = FrameMetadata(redactionReason: "private window", captureTrigger: .mouse,
                                     displayID: 42, mousePosition: CGPoint(x: 10, y: 20), isFocused: false)
        let frame = FrameReference(id: .init(value: 0), timestamp: Date(timeIntervalSince1970: 1),
                                  segmentID: .init(value: 1), frameIndexInSegment: 0, metadata: metadata)
        let id = try await database.insertFrame(frame, accessibilitySnapshot: nil)
        let fetched = try await database.getFrame(id: .init(value: id))
        XCTAssertEqual(fetched?.metadata.displayID, 42)
        XCTAssertEqual(fetched?.metadata.isFocused, false)
        XCTAssertEqual(fetched?.metadata.redactionReason, "private window")
        XCTAssertEqual(fetched?.metadata.captureTrigger, .mouse)
        let joined = try FrameQueries.getByIDWithVideoInfo(db: db, id: .init(value: id), storageRoot: "/tmp")
        XCTAssertEqual(joined?.frame.metadata.displayID, 42)
        XCTAssertEqual(joined?.frame.metadata.isFocused, false)
        XCTAssertEqual(joined?.frame.metadata.redactionReason, "private window")
        XCTAssertEqual(joined?.frame.metadata.captureTrigger, .mouse)
        try await database.close()
    }

    func testNativeInsertionRoundTripAndDeleteCleanup() async throws {
        let database = DatabaseManager(databasePath: "file:ocr_regions_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'test',0,10,0)", nil, nil, nil), SQLITE_OK)
        let regions = [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0, y: 0, width: 1, height: 1)]
        let frame = FrameReference(id: .init(value: 0), timestamp: Date(), segmentID: .init(value: 1),
                                  frameIndexInSegment: 0, metadata: FrameMetadata(ocrRegions: regions))
        let id = try await database.insertFrame(frame, accessibilitySnapshot: nil)
        let loaded = try await database.getFrameOCRRegions(frameID: id)
        XCTAssertEqual(loaded, regions)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_ocr_regions BEFORE INSERT ON frame_ocr_regions BEGIN SELECT RAISE(ABORT,'test'); END;", nil, nil, nil), SQLITE_OK)
        let countBefore = try await database.getFrameCount()
        do {
            _ = try await database.insertFrame(frame, accessibilitySnapshot: nil)
            XCTFail("Geometry insertion failure must roll back the native frame")
        } catch {}
        let countAfter = try await database.getFrameCount()
        XCTAssertEqual(countAfter, countBefore)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_ocr_regions", nil, nil, nil), SQLITE_OK)
        try await database.updateFrameProcessingStatus(frameID: id, status: 2, rewritePurpose: nil)
        let completed = try await database.getFrameOCRRegions(frameID: id)
        XCTAssertEqual(completed, regions, "Geometry must survive completion for deterministic reprocessing")
        XCTAssertEqual(sqlite3_exec(db, "UPDATE frame_ocr_regions SET payload=CAST('[]' AS BLOB)", nil, nil, nil), SQLITE_OK)
        let legacy = try await database.getFrameOCRRegions(frameID: id)
        XCTAssertNil(legacy, "Old fragment geometry must use legacy OCR, not window ownership masks")
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys=OFF", nil, nil, nil), SQLITE_OK)
        try await database.deleteFrame(id: .init(value: id))
        let deleted = try await database.getFrameOCRRegions(frameID: id)
        XCTAssertNil(deleted)
        try await database.close()
    }
}
