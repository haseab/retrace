import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class RetentionVideoDeletionTests: XCTestCase {
    func testRetentionDeletesOnlyUnreferencedCompletedVideosAndPropagatesFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("db.sqlite").path, storageRootPath: root.path)
        try await database.initialize()
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let sql = """
            INSERT INTO video(id,height,width,path,fileSize,frameRate,processingState) VALUES
              (1,100,100,'one',1,30,0),(2,100,100,'two',1,30,1),(3,100,100,'three',1,30,0),(4,100,100,'four',1,30,0);
            INSERT INTO frame(createdAt,imageFileName,videoId) VALUES (1,'frame',3);
            CREATE TRIGGER reject_retention_delete BEFORE DELETE ON video WHEN OLD.id=4
            BEGIN SELECT RAISE(ABORT,'simulated database write failure'); END;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let completed = try await database.deleteUnreferencedVideoSegment(id: VideoSegmentID(value: 1))
        let active = try await database.deleteUnreferencedVideoSegment(id: VideoSegmentID(value: 2))
        let referenced = try await database.deleteUnreferencedVideoSegment(id: VideoSegmentID(value: 3))
        let absent = try await database.deleteUnreferencedVideoSegment(id: VideoSegmentID(value: 99))
        XCTAssertTrue(completed)
        XCTAssertFalse(active)
        XCTAssertFalse(referenced)
        XCTAssertTrue(absent)
        do {
            _ = try await database.deleteUnreferencedVideoSegment(id: VideoSegmentID(value: 4))
            XCTFail("Deletion must propagate the SQLite failure")
        } catch {}
        try await database.close()
    }
}
