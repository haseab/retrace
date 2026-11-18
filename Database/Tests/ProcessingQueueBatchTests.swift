import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class ProcessingQueueBatchTests: XCTestCase {
    private final class Trace {
        var insertPrepares = 0
        var transactionStarts = 0
        var transactionEnds = 0
    }

    func testBatchReusesOneInsertStatementAndOneTransaction() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 500)
            let trace = Trace()
            sqlite3_set_authorizer(db, { context, action, table, _, _, _ in
                if let context, action == SQLITE_INSERT, let table, String(cString: table) == "processing_queue" {
                    Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue().insertPrepares += 1
                }
                return SQLITE_OK
            }, Unmanaged.passUnretained(trace).toOpaque())
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                let trace = Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue()
                let text = String(cString: sql)
                if text.hasPrefix("SAVEPOINT ") { trace.transactionStarts += 1 }
                if text.hasPrefix("RELEASE ") { trace.transactionEnds += 1 }
                return 0
            }, Unmanaged.passUnretained(trace).toOpaque())
            defer { sqlite3_set_authorizer(db, nil, nil); sqlite3_trace_v2(db, 0, nil, nil) }
            try await database.enqueueFramesForProcessing(frameIDs: (1...500).map(Int64.init), priority: 7)
            XCTAssertEqual(trace.insertPrepares, 1)
            XCTAssertEqual(trace.transactionStarts, 1)
            XCTAssertEqual(trace.transactionEnds, 1)
            let depth = try await database.getProcessingQueueDepth()
            XCTAssertEqual(depth, 500)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue WHERE priority=7 AND retryCount=0 AND enqueuedAt>0;"), 500)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM frame WHERE processingStatus=0;"), 500)
            try await database.enqueueFrameForProcessing(frameID: 500, priority: 99)
            let next = try await database.dequeueFrameForProcessing()
            XCTAssertEqual(next?.frameID, 500)
        }
    }

    func testMissingAndIneligibleFramesRollBackEntireBatch() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 5)
            for invalid in [Int64(5), 999] {
                for status in 1...4 {
                    try self.execute(db, "UPDATE frame SET processingStatus=? WHERE id=5;", bindings: [Int64(status)])
                    do {
                        try await database.enqueueFramesForProcessing(frameIDs: [1,2,invalid])
                        XCTFail("Missing/non-pending frames must fail the whole batch")
                    } catch {}
                    XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 0)
                    XCTAssertNotEqual(sqlite3_get_autocommit(db), 0)
                }
            }
        }
    }

    func testInsertFailureRollsBackBatchWithoutChangingExistingQueueEntries() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 500)
            try await database.enqueueFrameForProcessing(frameID: 500, priority: 12)
            try self.execute(db, """
                CREATE TRIGGER reject_queue_insert BEFORE INSERT ON processing_queue WHEN NEW.frameId=450
                BEGIN SELECT RAISE(ABORT,'injected insert failure'); END;
                """)
            do {
                try await database.enqueueFramesForProcessing(frameIDs: (1...500).map(Int64.init), priority: 3)
                XCTFail("Expected injected insert failure")
            } catch {}
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 1)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue WHERE frameId=500 AND priority=12;"), 1)
        }
    }

    func testEmptyDuplicateIDsAndCallerOwnedTransaction() async throws {
        try await withDatabase { database, db in
            try self.seed(db, count: 2)
            try await database.enqueueFramesForProcessing(frameIDs: [])
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 0)
            try self.execute(db, "BEGIN IMMEDIATE;")
            try await database.enqueueFramesForProcessing(frameIDs: [1,1], priority: -1)
            XCTAssertEqual(sqlite3_get_autocommit(db), 0)
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue WHERE frameId=1 AND priority=-1;"), 2)
            do {
                try await database.enqueueFramesForProcessing(frameIDs: [2,999])
                XCTFail("Expected batch failure")
            } catch {}
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 2)
            XCTAssertEqual(sqlite3_get_autocommit(db), 0)
            try self.execute(db, "ROLLBACK;")
            XCTAssertEqual(try self.count(db, "SELECT COUNT(*) FROM processing_queue;"), 0)
        }
    }

    private func seed(_ db: OpaquePointer, count: Int) throws {
        try execute(db, """
            WITH RECURSIVE n(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM n WHERE id<?)
            INSERT INTO frame(id,createdAt,imageFileName,processingStatus) SELECT id,1000,'frame',0 FROM n;
            """, bindings: [Int64(count)])
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
