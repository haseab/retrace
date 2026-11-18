import Foundation
import XCTest
import SQLCipher
import Shared
@testable import Database

final class FrameOCRRegionTests: XCTestCase {
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
