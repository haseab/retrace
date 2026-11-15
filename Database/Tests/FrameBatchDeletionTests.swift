import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class FrameBatchDeletionTests: XCTestCase {
    private final class StatementTrace {
        var frameDeletes = 0
    }

    func testRetentionDeletesInBatchesAndPreservesSharedSearchDocuments() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 1_101)
            try self.execute(db, """
                INSERT INTO frame(id,createdAt,imageFileName) VALUES (2001,2000,'boundary'),(2002,3000,'newer');
                INSERT INTO searchRanking(rowid,text) VALUES (9001,'sharedtoken'),(9002,'audiotoken'),(9003,'crossbatchtoken'),(9004,'unrelatedtoken');
                INSERT INTO doc_segment(docid,segmentId,frameId) VALUES
                  (9001,0,1),(9001,0,2001),(9002,0,2),(9002,0,NULL),(9003,0,500),(9003,0,1001);
                INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height)
                  VALUES (1,0,0,1,0,0,1,1),(2001,0,0,1,0,0,1,1);
                INSERT INTO processing_queue(frameId,enqueuedAt) VALUES (1,1000),(2001,1000);
                """)
            let trace = StatementTrace()
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement,
                      let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                // PROFILE fires on statement completion; STMT is also emitted for
                // each FK cascade subprogram and would overcount a batched delete.
                if String(cString: sql).hasPrefix("DELETE FROM frame WHERE") {
                    Unmanaged<StatementTrace>.fromOpaque(context).takeUnretainedValue().frameDeletes += 1
                }
                return 0
            }, Unmanaged.passUnretained(trace).toOpaque())
            defer { sqlite3_trace_v2(db, 0, nil, nil) }

            let deleted = try await database.deleteFrames(olderThan: Date(timeIntervalSince1970: 2))
            XCTAssertEqual(deleted, 1_101)
            XCTAssertEqual(trace.frameDeletes, 3, "Frame deletes must scale with chunks, not frames")
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 2)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredtoken';"), 0)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'sharedtoken OR audiotoken OR unrelatedtoken';"), 3)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'crossbatchtoken';"), 0)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM doc_segment;"), 2)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM node;"), 1)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 1)
            try self.execute(db, "INSERT INTO searchRanking(searchRanking) VALUES('integrity-check');")
        }
    }

    func testFailureInLaterBatchRollsBackFramesLinksAndSearchIndex() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 1_101)
            try self.execute(db, """
                CREATE TRIGGER fail_late_delete BEFORE DELETE ON frame WHEN OLD.id=1001
                BEGIN SELECT RAISE(ABORT,'injected deletion failure'); END;
                """)
            do {
                _ = try await database.deleteFrames(olderThan: Date(timeIntervalSince1970: 2))
                XCTFail("Expected the injected SQLite failure")
            } catch {}
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 1_101)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM doc_segment;"), 1_101)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredtoken';"), 1_101)
            XCTAssertNotEqual(sqlite3_get_autocommit(db), 0)
            try self.execute(db, "INSERT INTO searchRanking(searchRanking) VALUES('integrity-check');")
        }
    }

    func testExplicitIDsRespectBindingLimitAndCallerTransaction() async throws {
        try await withDatabase { _, db in
            try self.seed(db, count: 301)
            let originalLimit = sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 64)
            defer { sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, originalLimit) }
            try self.execute(db, "BEGIN IMMEDIATE;")
            let deleted = try FrameQueries.delete(db: db, frameIDs: (1...301).map { FrameID(value: Int64($0)) })
            XCTAssertEqual(deleted, 301)
            XCTAssertEqual(sqlite3_get_autocommit(db), 0, "Deletion must not commit its caller's transaction")
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 0)
            try self.execute(db, "ROLLBACK;")
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 301)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredtoken';"), 301)
        }
    }

    func testManyDocumentsForOneFrameRespectBindingLimit() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 1)
            try self.execute(db, """
                WITH RECURSIVE n(id) AS (VALUES(2) UNION ALL SELECT id+1 FROM n WHERE id<301)
                INSERT INTO searchRanking(rowid,text) SELECT id,'extratoken' FROM n;
                INSERT INTO doc_segment(docid,segmentId,frameId) SELECT rowid,0,1 FROM searchRanking WHERE rowid>1;
                """)
            let originalLimit = sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 64)
            defer { sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, originalLimit) }
            try await database.deleteFrame(id: FrameID(value: 1))
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 0)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM doc_segment;"), 0)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking;"), 0)
        }
    }

    func testEmptyMissingAndDuplicateIDsPreserveExistingCountSemantics() async throws {
        try await withDatabase { _, db in
            try self.seed(db, count: 2)
            XCTAssertEqual(try FrameQueries.delete(db: db, frameIDs: []), 0)
            let deleted = try FrameQueries.delete(db: db, frameIDs: [1,1,999].map { FrameID(value: Int64($0)) })
            XCTAssertEqual(deleted, 3, "Existing API counts requested IDs, including duplicates and missing IDs")
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame;"), 1)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredtoken';"), 1)
        }
    }

    func testNewerThanDeletionPreservesBoundaryAndUnindexedFramesWork() async throws {
        try await withDatabase { database, db in
            try self.execute(db, "INSERT INTO frame(id,createdAt,imageFileName) VALUES (1,1000,'old'),(2,2000,'boundary'),(3,3000,'new');")
            let deleted = try await database.deleteFrames(newerThan: Date(timeIntervalSince1970: 2))
            XCTAssertEqual(deleted, 1)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame WHERE id IN (1,2);"), 2)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame WHERE id=3;"), 0)
        }
    }

    func testReindexingPreservesSearchDocumentSharedWithAnotherFrame() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 2)
            try self.execute(db, "INSERT INTO doc_segment(docid,segmentId,frameId) VALUES (1,0,2);")
            _ = try await database.indexFrameText(
                mainText: "replacementtoken", chromeText: nil, windowTitle: nil, segmentId: 0, frameId: 1
            )
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM doc_segment WHERE frameId=1;"), 1)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'expiredtoken';"), 2)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'replacementtoken';"), 1)
            try self.execute(db, "INSERT INTO searchRanking(searchRanking) VALUES('integrity-check');")
        }
    }

    private func seed(_ db: OpaquePointer, count: Int) throws {
        try execute(db, """
            WITH RECURSIVE n(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM n WHERE id<?)
            INSERT INTO frame(id,createdAt,imageFileName) SELECT id,1000,'frame' FROM n;
            """, bindings: [Int64(count)])
        try execute(db, """
            INSERT INTO searchRanking(rowid,text) SELECT id,'expiredtoken' FROM frame;
            INSERT INTO doc_segment(docid,segmentId,frameId) SELECT id,0,id FROM frame;
            """)
    }

    private func withDatabase(_ operation: (DatabaseManager, OpaquePointer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("db.sqlite").path, storageRootPath: root.path)
        try await database.initialize()
        do {
            let connection = await database.getConnection()
            let db = try XCTUnwrap(connection)
            try await operation(database, db)
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String, bindings: [Int64] = []) throws {
        if !bindings.isEmpty {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }
            for (index, value) in bindings.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }
            return
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func count(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
