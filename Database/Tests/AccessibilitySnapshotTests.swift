import Foundation
import XCTest
import SQLCipher
import Shared
@testable import Database

final class AccessibilitySnapshotTests: XCTestCase {
    func testEncryptedSnapshotAuthenticationAndSizeLimit() throws {
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [.init(text: "private canary", bounds: .zero, precise: false)])
        let key = Data(repeating: 42, count: 32)
        let sealed = try snapshot.sealed(masterKey: key, identity: "frame:1")
        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "private canary"))
        XCTAssertEqual(try AccessibilitySnapshot.open(sealed, masterKey: key, identity: "frame:1"), snapshot)
        XCTAssertThrowsError(try AccessibilitySnapshot.open(sealed, masterKey: key, identity: "frame:2"))
        XCTAssertThrowsError(try AccessibilitySnapshot.open(sealed, masterKey: Data(repeating: 1,count: 32), identity: "frame:1"))
    }

    func testSnapshotLifecycleAndAtomicFrameInsertion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("db.sqlite").path, storageRootPath: root.path)
        try await database.initialize()
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteTest", code: 1, userInfo: nil)
            }
        }
        func count(_ sql: String) throws -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
                throw NSError(domain: "SQLiteTest", code: 2, userInfo: nil)
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
        try execute("INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES (1,'test',1,2,0);")
        let frame = FrameReference(id: .init(value: 0), timestamp: Date(), segmentID: .init(value: 1), frameIndexInSegment: 0, metadata: .empty)
        let id = try await database.insertFrame(frame, accessibilitySnapshot: nil)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM frame_accessibility WHERE frame_id=\(id) AND state='unavailable'"), 1)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [.init(text: "private reference", bounds: .zero, precise: false)])
        let key = Data(repeating: 42, count: 32)
        try execute("DELETE FROM frame_accessibility WHERE frame_id=\(id);")
        try AccessibilitySnapshotQueries.insert(db: db, frameID: id, snapshot: snapshot, keyProvider: { key })
        XCTAssertEqual(try AccessibilitySnapshotQueries.load(db: db, frameID: id, keyProvider: { key }), snapshot)
        try await database.updateFrameProcessingStatus(frameID: id, status: 0, rewritePurpose: nil)
        let pending = try await database.hasFramesAwaitingOCR()
        XCTAssertTrue(pending)
        XCTAssertEqual(try AccessibilitySnapshotQueries.load(db: db, frameID: id, keyProvider: { key }), snapshot)
        try await database.updateFrameProcessingStatus(frameID: id, status: 5, rewritePurpose: "redaction")
        XCTAssertNil(try AccessibilitySnapshotQueries.load(db: db, frameID: id, keyProvider: { key }))
        let pendingAfter = try await database.hasFramesAwaitingOCR()
        XCTAssertFalse(pendingAfter)
        try execute("CREATE TRIGGER reject_ax BEFORE INSERT ON frame_accessibility BEGIN SELECT RAISE(ABORT,'test'); END;")
        let before = try count("SELECT COUNT(*) FROM frame")
        do {
            _ = try await database.insertFrame(frame, accessibilitySnapshot: nil)
            XCTFail("Snapshot insert failure must roll back the frame")
        } catch {}
        XCTAssertEqual(try count("SELECT COUNT(*) FROM frame"), before)
        try execute("DROP TRIGGER reject_ax; PRAGMA foreign_keys=OFF;")
        try await database.deleteFrame(id: .init(value: id))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM frame_accessibility"), 0)
        try await database.close()
    }
}
